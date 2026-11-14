(function (global) {
  'use strict';
  const SETTINGS = /^reader_(?:ai_provider$|openai_|ollama_|voice_|doubao_|paragraph_voice_|device_identity|daily_report_preferences|supabase|bundled_library_seeded)/;
  const BRIDGE_KEY = 'vocabmaster_reader_inbox_v1';
  const managed = key => key === 'my_local_articles' || key === 'my_local_vocab_book' || (key.startsWith('reader_') && !SETTINGS.test(key));
  const safeStore = name => { try { return global[name]; } catch (_) { return null; } };
  global.createReaderStorage = function (options = {}) {
    const local = options.localStorage || safeStore('localStorage');
    const session = options.sessionStorage || safeStore('sessionStorage');
    const memory = new Map(), pending = new Map(), listeners = new Set();
    let db, error = null, running = Promise.resolve(), channel, archiveSequence = 0;
    const read = (store, key) => { try { return store?.getItem(key) ?? null; } catch (_) { return null; } };
    const scan = store => { try { return Object.keys(store || {}).map(key => [key, read(store, key)]).filter(([, value]) => typeof value === 'string'); } catch (_) { return []; } };
    const notify = () => listeners.forEach(listener => { try { listener(api.status()); } catch (_) {} });
    const transaction = entries => new Promise((resolve, reject) => {
      let tx;
      try {
        tx = db.transaction('records', 'readwrite');
        tx.oncomplete = resolve; tx.onerror = tx.onabort = () => reject(tx.error || new Error('Storage transaction failed'));
        const store = tx.objectStore('records');
        entries.forEach(([key, value]) => value === null ? store.delete(key) : store.put(value, key));
      } catch (failure) { try { tx?.abort(); } catch (_) {} reject(failure); }
    });
    const load = () => new Promise((resolve, reject) => {
      const received = new Map();
      const tx = db.transaction('records'), request = tx.objectStore('records').openCursor();
      request.onsuccess = () => { const cursor = request.result; if (cursor) { received.set(cursor.key, cursor.value); cursor.continue(); } };
      tx.oncomplete = () => {
        for (const key of memory.keys()) if (!pending.has(key)) memory.delete(key);
        received.forEach((value, key) => { if (!pending.has(key)) memory.set(key, value); }); resolve();
      };
      tx.onerror = tx.onabort = () => reject(tx.error || new Error('Storage read failed'));
    });
    const commit = async () => {
      if (!pending.size) return;
      try {
        if (!db) throw new Error('学习记录数据库不可用，修改暂存在当前页面');
        const entries = [...pending];
        const sources = entries.map(([key]) => [key, read(local, key), read(session, key)]);
        await transaction(entries);
        entries.forEach(([key, value]) => { if (pending.get(key) === value) pending.delete(key); });
        sources.forEach(([key, legacy, fallback]) => {
          for (const [store, old] of [[local, legacy], [session, fallback]]) {
            try { if (old !== null && read(store, key) === old) store.removeItem(key); } catch (_) {}
          }
        });
        error = null; channel?.postMessage(entries.map(([key]) => key)); notify();
      } catch (failure) {
        // Emergency quiz recovery is tab-scoped, never a durable-save acknowledgement.
        for (const [key, value] of pending) {
          if (key.startsWith('reader_quiz_progress_') && value !== null) {
            try { session?.setItem(key, value); } catch (_) {}
          }
        }
        error = failure.message; notify(); throw failure;
      }
    };
    const migrate = async () => {
      const currentWrites = new Set(pending.keys());
      let settingsBytes = 0;
      const originPressure = api.status().localStorageBytes >= 4 * 1024 * 1024;
      const conflicts = [];
      for (const [key, value] of scan(local)) {
        const bytes = 2 * (key.length + value.length);
        const settingOverflow = SETTINGS.test(key) && (originPressure || bytes > 8192 || settingsBytes + bytes > 512 * 1024);
        if (SETTINGS.test(key) && !settingOverflow) settingsBytes += bytes;
        if (managed(key) || settingOverflow) {
          if (!memory.has(key)) { memory.set(key, value); pending.set(key, value); }
          else if (memory.get(key) !== value && !pending.has(key)) {
            // Preserve a conflicting legacy copy before freeing its native quota.
            const archiveKey = `reader_migration_backup_${Date.now()}_${++archiveSequence}_${key}`;
            memory.set(archiveKey, value); pending.set(archiveKey, value); conflicts.push([key, value]);
          }
        }
      }
      for (const [key, value] of scan(session)) {
        if (key.startsWith('reader_quiz_progress_') && !currentWrites.has(key)) { memory.set(key, value); pending.set(key, value); }
      }
      // Clean redundant native copies only after every migration write commits.
      await commit();
      for (const [key, value] of conflicts) {
        try { if (read(local, key) === value) local.removeItem(key); } catch (_) {}
      }
      for (const [key, value] of scan(local)) {
        if (managed(key) && memory.get(key) === value && !pending.has(key)) {
          try { if (read(local, key) === value) local.removeItem(key); } catch (_) {}
        }
      }
    };
    const api = {
      isManagedKey: managed,
      getItem(key) { return memory.has(key) ? memory.get(key) : read(local, key); },
      setItem(key, value) {
        value = String(value);
        if (key === BRIDGE_KEY) {
          try {
            const old = read(local, key);
            const previousBytes = old === null ? 0 : 2 * (key.length + old.length);
            const bytes = 2 * (key.length + value.length);
            if (bytes > 64 * 1024 || api.status().appBytes - previousBytes + bytes > 512 * 1024) throw new Error('共享词卡超过本机交换空间预算，请使用导出或云同步');
            local.setItem(key, value); return true;
          } catch (failure) { error = failure.message; notify(); return false; }
        }
        if (!managed(key) && !memory.has(key) && SETTINGS.test(key)) {
          const bytes = 2 * (key.length + value.length), old = read(local, key);
          const previousBytes = old === null ? 0 : 2 * (key.length + old.length);
          if (bytes <= 8192 && !api.status().pressure && api.status().appBytes - previousBytes + bytes <= 512 * 1024) {
            try { local.setItem(key, value); return true; } catch (_) {}
          }
        }
        if (memory.get(key) === value) return true;
        memory.set(key, value); pending.set(key, value); notify(); api.flush().catch(() => {}); return true;
      },
      removeItem(key) {
        if (!managed(key) && !memory.has(key)) { try { local?.removeItem(key); } catch (_) {} return; }
        memory.set(key, null); pending.set(key, null); notify(); api.flush().catch(() => {});
      },
      keys() { return [...new Set([...scan(local).map(([key]) => key), ...memory.keys()])].filter(key => api.getItem(key) !== null); },
      flush() { running = running.catch(() => {}).then(() => api.ready).then(commit); return running; },
      async maintain() { await api.ready; await api.flush(); await migrate(); notify(); return api.status(); },
      status() {
        const sizes = scan(local).map(([key, value]) => ({ key, bytes: 2 * (key.length + value.length) })).sort((a, b) => b.bytes - a.bytes);
        const appBytes = sizes.filter(item => item.key.startsWith('reader_') || item.key.startsWith('my_local_') || item.key === BRIDGE_KEY).reduce((sum, item) => sum + item.bytes, 0);
        return { localStorageBytes: sizes.reduce((sum, item) => sum + item.bytes, 0), appBytes, topKeys: sizes.slice(0, 10), budgetBytes: 512 * 1024, settingLimitBytes: 8192, pressure: appBytes > 512 * 1024 || sizes.reduce((sum, item) => sum + item.bytes, 0) >= 4 * 1024 * 1024, indexedDB: Boolean(db), pending: pending.size, error };
      },
      subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
      dispose() { channel?.close(); db?.close(); }
    };
    api.ready = new Promise(resolve => {
      try {
        const request = (options.indexedDB || global.indexedDB).open('reader-learning-data-v1', 1);
        request.onupgradeneeded = () => request.result.createObjectStore('records');
        const degraded = async () => { error = '无法打开学习记录数据库'; try { await migrate(); } catch (_) {} notify(); resolve(); };
        request.onerror = request.onblocked = degraded;
        request.onsuccess = async () => {
          db = request.result;
          db.onversionchange = () => { db.close(); db = null; error = '学习数据库版本已变更，请重新打开页面'; notify(); };
          try { await load(); }
          catch (failure) {
            // Never make an unreadable database writable with empty app defaults.
            db.close(); db = null;
            error = '读取已有学习记录失败，请重新打开页面；原数据库未被覆盖';
            notify(); resolve(); return;
          }
          try { await migrate(); } catch (failure) { error = failure.message; }
          notify(); resolve();
        };
      } catch (failure) { error = failure.message; migrate().catch(() => {}).finally(() => { notify(); resolve(); }); }
    });
    try { channel = new global.BroadcastChannel('reader-learning-data-v1'); channel.onmessage = event => {
      if (!db || !Array.isArray(event.data)) return;
      try {
        const tx = db.transaction('records');
        for (const key of event.data) {
          if (typeof key !== 'string') continue;
          const request = tx.objectStore('records').get(key);
          request.onsuccess = () => {
            if (pending.has(key)) return;
            if (request.result === undefined) memory.delete(key);
            else memory.set(key, request.result);
          };
        }
        tx.oncomplete = notify;
        tx.onerror = tx.onabort = () => { error = '读取其他页面的存储更新失败'; notify(); };
      } catch (failure) { error = failure.message; notify(); }
    }; } catch (_) {}
    return api;
  };
})(typeof window === 'undefined' ? globalThis : window);
