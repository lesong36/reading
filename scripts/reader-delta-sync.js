(function (global) {
  'use strict';

  const bytes = value => new TextEncoder().encode(JSON.stringify(value)).length;
  const keyOf = (type, id) => JSON.stringify([type, id]);
  global.createReaderDeltaSync = function ({
    client,
    userID,
    isCurrentAccount = () => true,
    onStatus = () => {},
    indexedDB = global.indexedDB
  }) {
    let observed = {};
    let db,
      state = {
        entities: {},
        pending: [],
        epoch: null,
        cursor: 0,
        lastSuccess: null
      },
      running;
    const check = () => {
      if (!isCurrentAccount()) throw new Error('账号已切换');
    };
    const load = () => new Promise((resolve, reject) => {
      const tx = db.transaction(['meta', 'entities', 'outbox']);
      const next = {
        entities: {},
        pending: [],
        epoch: null,
        cursor: 0,
        lastSuccess: null
      };
      const meta = tx.objectStore('meta').get(userID);
      meta.onsuccess = () => Object.assign(next, meta.result || {});
      for (const name of ['entities', 'outbox']) {
        const r = tx.objectStore(name).index('owner').getAll(userID);
        r.onsuccess = () => {
          for (const row of r.result || []) {
            if (name === 'entities') next.entities[row.key] = row.value;else next.pending.push(row.value);
          }
        };
      }
      tx.oncomplete = () => {
        next.pending.sort((a, b) => (a.order || 0) - (b.order || 0));
        state = next;
        resolve();
      };
      tx.onerror = tx.onabort = () => reject(tx.error || new Error('本机读取失败'));
    });
    const save = next => new Promise((resolve, reject) => {
      check();
      const tx = db.transaction(['meta', 'entities', 'outbox', 'recovery'], 'readwrite');
      const {
        entities: ignoredEntities,
        pending: ignoredPending,
        recoveryEntities,
        ...meta
      } = next;
      if (recoveryEntities) {
        tx.objectStore('recovery').put(recoveryEntities, [userID, next.recoveryBackup.archiveID]);
        delete next.recoveryEntities;
      }
      tx.objectStore('meta').put(meta, userID);
      for (const key of Object.keys(state.entities)) if (!(key in next.entities)) tx.objectStore('entities').delete([userID, key]);
      for (const [key, value] of Object.entries(next.entities)) if (JSON.stringify(state.entities[key]) !== JSON.stringify(value)) tx.objectStore('entities').put({
        owner: userID,
        key,
        value
      }, [userID, key]);
      const ids = new Set(next.pending.map(o => o.operationID));
      for (const op of state.pending) if (!ids.has(op.operationID)) tx.objectStore('outbox').delete([userID, op.operationID]);
      const old = new Map(state.pending.map(o => [o.operationID, JSON.stringify(o)]));
      for (const value of next.pending) if (old.get(value.operationID) !== JSON.stringify(value)) tx.objectStore('outbox').put({
        owner: userID,
        key: value.operationID,
        value
      }, [userID, value.operationID]);
      tx.oncomplete = () => {
        state = next;
        try {
          onStatus(api.snapshot());
        } catch (_) {}
        resolve();
      };
      tx.onerror = tx.onabort = () => reject(tx.error || new Error('本机持久化失败'));
    });
    const rpc = async (name, args) => {
      check();
      let timer;
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('网络请求超时，待确认操作已保留')), 15000);
      });
      let response;
      try {
        response = await Promise.race([client.rpc(name, args), timeout]);
      } finally {
        clearTimeout(timer);
      }
      const {
        data,
        error
      } = response;
      check();
      if (error) throw error;
      return data;
    };
    let mutation = Promise.resolve();
    const serialize = fn => {
      const result = mutation.then(() => global.navigator?.locks ? global.navigator.locks.request('reader-delta:' + userID, async () => {
        await load();
        return fn();
      }) : Promise.reject(new Error('浏览器缺少跨页面事务锁，停止云同步以保护队列')));
      mutation = result.catch(() => {});
      return result;
    };
    const api = {
      async open() {
        db = await new Promise((resolve, reject) => {
          const r = indexedDB.open('reader-delta-v1', 3);
          r.onupgradeneeded = () => {
            for (const name of ['meta', 'entities', 'outbox', 'recovery']) if (!r.result.objectStoreNames.contains(name)) {
              const store = r.result.createObjectStore(name);
              if (name !== 'meta') store.createIndex('owner', 'owner');
            }
          };
          r.onsuccess = () => resolve(r.result);
          r.onerror = () => reject(r.error);
        });
        await load();
        return api;
      },
      snapshot() {
        return structuredClone({
          ...state,
          protocol: 3,
          userID
        });
      },
      enqueue(entityType, entityID, payload, deleted = false, baselineVersion = null) {
        return serialize(async () => {
          check();
          const k = keyOf(entityType, entityID),
            old = state.entities[k];
          const op = {
            operationID: global.crypto.randomUUID(),
            order: (state.nextOrder || 0) + 1,
            entityType,
            entityID,
            baseVersion: baselineVersion ?? (old?.version || 0),
            kind: deleted ? 'delete' : old?.deleted ? 'restore' : 'upsert',
            payload
          };
          await save({
            ...state,
            nextOrder: op.order,
            pending: [...state.pending, op],
            entities: {
              ...state.entities,
              [k]: {
                entityType,
                entityID,
                payload,
                deleted,
                version: old?.version || 0
              }
            }
          });
          return op.operationID;
        });
      },
      async enqueueQuizChange(event) {
        return serialize(async () => {
          check();
          const pending = [...state.pending],
            entities = {
              ...state.entities
            };
          let nextOrder = state.nextOrder || 0;
          const affected = [];
          const add = (entityType, entityID, payload, deleted = false) => {
            const key = keyOf(entityType, entityID),
              old = entities[key];
            pending.push({
              operationID: global.crypto.randomUUID(),
              order: ++nextOrder,
              entityType,
              entityID,
              payload,
              baseVersion: observed[key]?.version || 0,
              kind: deleted ? 'delete' : observed[key]?.deleted ? 'restore' : 'upsert'
            });
            affected.push({key, version: observed[key]?.version || 0});
            entities[key] = {
              entityType,
              entityID,
              payload,
              deleted,
              version: old?.version || 0
            };
          };
          add('answer_event', event.eventID, event);
          const metaKey = keyOf('quiz_meta', event.articleID),
            meta = {
              ...observed[metaKey]?.payload
            };
          let metaChanged = false;
          for (const [field, value] of Object.entries(event.changes)) {
            if (['answers', 'locatorSentenceIds', 'answerUpdatedAt', 'answerDeletedAt', 'locatorUpdatedAt', 'locatorDeletedAt'].includes(field)) {
              for (const [id, payload] of Object.entries(value)) add('quiz_' + field, JSON.stringify([event.articleID, id]), payload, payload === null);
            } else {
              meta[field] = value;
              metaChanged = true;
            }
          }
          if (metaChanged) add('quiz_meta', event.articleID, meta);
          await save({
            ...state,
            pending,
            nextOrder,
            entities
          });
          for (const {key, version} of affected) if (entities[key].entityType !== 'answer_event') observed[key] = {...entities[key], version};
          return event.eventID;
        });
      },
      sync() {
        if (running) return running;
        running = global.navigator.locks.request('reader-delta-send:' + userID, async () => {
          await mutation;
          await serialize(async () => {});
          let more = true;
          while (more) {
            check();
            let operations = [];
            for (const op of state.pending) {
              if (state.conflicts?.[op.operationID]) continue;
              if (operations.some(previous => keyOf(previous.entityType, previous.entityID) === keyOf(op.entityType, op.entityID))) break;
              const next = [...operations, op];
              if (next.length > 50 || bytes({
                p_operations: next
              }) > 102400) break;
              operations = next;
            }
            if (operations.some(op => bytes(op) > 64000)) throw new Error('单项超过服务端64 KiB限制，原数据和队列已保留');
            if (state.pending.some(o => !state.conflicts?.[o.operationID]) && !operations.length) throw new Error('单项超过100 KiB，原数据和队列已保留');
            if (operations.length) {
              const result = await rpc('reader_delta_push', {
                p_operations: operations
              });
              await serialize(async () => {
                const acks = result.acknowledgements || result.acks || [];
                if (acks.some(a => !operations.some(o => o.operationID === a.operationID) || !['applied', 'duplicate', 'conflict'].includes(a.status) || !Number.isSafeInteger(a.version) || a.version < 0) || new Set(acks.map(a => a.operationID)).size !== acks.length) throw new Error('无效确认响应');
                const confirmed = new Map(acks.filter(a => a.status !== 'conflict').map(a => [a.operationID, a]));
                const conflicts = {
                  ...state.conflicts
                };
                for (const ack of acks) if (ack.status === 'conflict') conflicts[ack.operationID] = ack;
                await save({
                  ...state,
                  conflicts,
                  pending: state.pending.filter(o => !confirmed.has(o.operationID)).map(o => {
                    const previous = operations.find(p => p.entityType === o.entityType && p.entityID === o.entityID && confirmed.has(p.operationID));
                    return previous ? {
                      ...o,
                      baseVersion: confirmed.get(previous.operationID).version
                    } : o;
                  }),
                  entities: Object.fromEntries(Object.entries(state.entities).map(([k, e]) => {
                    const op = operations.find(o => keyOf(o.entityType, o.entityID) === k && confirmed.has(o.operationID));
                    return [k, op ? {
                      ...e,
                      version: confirmed.get(op.operationID).version
                    } : e];
                  }))
                });
                for (const op of operations) {
                  const key = keyOf(op.entityType, op.entityID);
                  if (confirmed.has(op.operationID) && observed[key] && JSON.stringify(observed[key].payload) === JSON.stringify(op.payload) && observed[key].deleted === (op.kind === 'delete')) observed[key] = {...observed[key], version: confirmed.get(op.operationID).version};
                }
              });
              if (!acksLength(result)) throw new Error('服务端未确认操作');
            }
            const unresolved = Object.entries(state.conflicts || {}).filter(([, c]) => !c.server);
            if (unresolved.length) {
              const wanted = unresolved.map(([id]) => state.pending.find(o => o.operationID === id)).filter(Boolean).slice(0, 50).map(o => ({
                entityType: o.entityType,
                entityID: o.entityID
              }));
              const response = await rpc('reader_delta_get', {
                p_entities: wanted
              });
              if (!Array.isArray(response.entities)) throw new Error('冲突记录响应无效');
              await serialize(async () => {
                const conflicts = {
                  ...state.conflicts
                };
                for (const [id] of unresolved) {
                  const op = state.pending.find(o => o.operationID === id);
                  const server = response.entities.find(e => e.entityType === op?.entityType && e.entityID === op?.entityID);
                  if (server) conflicts[id] = {
                    ...conflicts[id],
                    server
                  };
                }
                await save({
                  ...state,
                  conflicts
                });
              });
            }
            const page = await rpc('reader_delta_pull', {
              p_epoch: state.epoch,
              p_cursor: state.cursor,
              p_limit: 50
            });
            if (page.resetRequired) {
              await serialize(async () => {
                const pendingKeys = new Set(state.pending.map(o => keyOf(o.entityType, o.entityID)));
                const entities = Object.fromEntries(Object.entries(state.entities).filter(([k]) => pendingKeys.has(k)));
                await save({
                  ...state,
                  recoveryBackup: {
                    archiveID: global.crypto.randomUUID(),
                    count: Object.keys(state.entities).length,
                    epoch: state.epoch,
                    cursor: state.cursor
                  },
                  recoveryEntities: state.entities,
                  entities,
                  epoch: page.epoch,
                  cursor: 0,
                  captureKeys: []
                });
              });
              continue;
            }
            if (!Number.isSafeInteger(page.nextCursor) || page.nextCursor < state.cursor || typeof page.epoch !== 'string' || state.epoch && page.epoch !== state.epoch || !Array.isArray(page.changes) || page.changes.length > 50 || bytes(page) > 131072) throw new Error('无效或超限变化页');
            await serialize(async () => {
              if (page.nextCursor < state.cursor) throw new Error('变化游标已更新，请重试');
              let entities = {
                ...state.entities
              };
              for (const e of page.changes) {
                const k = keyOf(e.entityType, e.entityID);
                const pending = state.pending.filter(o => keyOf(o.entityType, o.entityID) === k);
                if (!pending.length) {
                  if (!entities[k] || e.version >= entities[k].version) entities[k] = e;
                } else for (const op of pending) if (state.conflicts?.[op.operationID]) state.conflicts[op.operationID] = {
                  ...state.conflicts[op.operationID],
                  server: e
                };
              }
              await save({
                ...state,
                entities,
                epoch: page.epoch,
                cursor: page.nextCursor,
                lastSuccess: new Date().toISOString()
              });
            });
            more = page.hasMore || state.pending.some(o => !state.conflicts?.[o.operationID]);
          }
          if (Object.keys(state.conflicts || {}).length) throw new Error('实体版本冲突，待确认操作已保留');
        }).catch(error => {
          onStatus({
            ...api.snapshot(),
            error: error.message
          });
          throw error;
        }).finally(() => {
          running = null;
        });
        return running;
      },
      async resolveConflict(operationID, choice) {
        if (!['keep-server', 'keep-local'].includes(choice)) throw new Error('请选择保留本机或云端');
        await serialize(async () => {
          const conflict = state.conflicts?.[operationID],
            op = state.pending.find(o => o.operationID === operationID);
          if (!conflict || !op) throw new Error('未找到待处理冲突');
          if (op.entityType === 'answer_event' && choice === 'keep-local') throw new Error('答题事件不可覆盖');
          const conflicts = {
            ...state.conflicts
          };
          delete conflicts[operationID];
          let pending = state.pending.filter(o => o.operationID !== operationID);
          const key = keyOf(op.entityType, op.entityID);
          let entities = {
            ...state.entities
          };
          if (choice === 'keep-server') {
            if (!conflict.server) throw new Error('请先读取云端冲突记录');
            entities[key] = conflict.server;
          } else {
            pending.push({
              ...op,
              operationID: global.crypto.randomUUID(),
              baseVersion: conflict.version,
              kind: op.kind === 'delete' ? 'delete' : conflict.deleted ? 'restore' : 'upsert'
            });
          }
          await save({
            ...state,
            conflicts,
            pending,
            entities
          });
        });
      },
      async captureSnapshot(snapshot, partial = false) {
        const desired = {};
        const add = (t, id, p) => desired[keyOf(t, id)] = {
          entityType: t,
          entityID: id,
          payload: p
        };
        for (const field of ['reading_positions', 'completion_records', 'preferences']) for (const [id, p] of Object.entries(snapshot[field] || {})) add(field, id, p);
        for (const id of snapshot.favorites || []) add('favorite', id, true);
        for (const entry of snapshot.vocabulary || []) add('vocabulary', String(entry.word || '').trim().toLowerCase(), entry);
        if (snapshot.encrypted_ai_key) add('encrypted_ai_key', 'default', snapshot.encrypted_ai_key);
        for (const [article, p] of Object.entries(snapshot.quiz_progress || {})) {
          for (const field of ['answers', 'locatorSentenceIds', 'answerUpdatedAt', 'answerDeletedAt', 'locatorUpdatedAt', 'locatorDeletedAt']) for (const [id, value] of Object.entries(p[field] || {})) add('quiz_' + field, JSON.stringify([article, id]), value);
          const meta = {
            ...p
          };
          for (const field of ['answers', 'locatorSentenceIds', 'answerUpdatedAt', 'answerDeletedAt', 'locatorUpdatedAt', 'locatorDeletedAt']) delete meta[field];
          add('quiz_meta', article, meta);
        }
        for (const [k, e] of Object.entries(desired)) {
          if (!partial && e.entityType.startsWith('quiz_')) continue;
          const old = partial ? state.entities[k] : observed[k];
          if (partial && old) continue;
          if (!old || old.deleted || JSON.stringify(old.payload) !== JSON.stringify(e.payload)) {
            await api.enqueue(e.entityType, e.entityID, e.payload, false, partial ? null : (old?.version || 0));
            if (!partial) observed[k] = { ...e, deleted: false, version: old?.version || 0 };
          }
        }
        if (!partial) for (const [k, e] of Object.entries(observed)) {
          if (e.entityType === 'answer_event' || e.entityType.startsWith('quiz_') || desired[k] || e.deleted) continue;
          await api.enqueue(e.entityType, e.entityID, null, true, e.version || 0);
          observed[k] = { ...e, deleted: true };
        }
      },
      async migrateLegacy() {
        const activation = await rpc('reader_delta_activate', {});
        if (activation.migrationVerified) {
          await api.sync();
          return [];
        }
        await api.sync();
        const manifest = await rpc('reader_delta_legacy_manifest', {});
        for (const entry of manifest) {
          const field = entry.field;
          let after = state.migration?.[field] || '';
          if (after === '__complete__') continue;
          let more = true;
          while (more) {
            const page = await rpc('reader_delta_legacy_page', {
              p_field: field,
              p_after: after,
              p_limit: 50
            });
            if (!Array.isArray(page.items) || page.items.length > 50) throw new Error('迁移页无效');
            for (const row of page.items) {
              const data = {};
              if (field === 'vocab_tombstones') {
                const wordKey = String(row.payload.wordKey || '').trim().toLowerCase();
                if (!wordKey) throw new Error('旧删除记录缺少词条ID，原数据已保留');
                const known = state.entities[keyOf('vocabulary', wordKey)];
                if (!known?.deleted) await api.enqueue('vocabulary', wordKey, null, true);
                continue;
              }
              if (field === 'vocabulary') data[field] = [row.payload];else if (field === 'favorites') data[field] = [row.payload];else if (field === 'encrypted_ai_key') data[field] = row.payload;else data[field] = {
                [row.id]: row.payload
              };
              await api.captureSnapshot(data, true);
            }
            await api.sync();
            for (const row of page.items) await rpc('reader_delta_stage_legacy', {
              p_field: field,
              p_id: row.id,
              p_payload: row.payload
            });
            after = page.nextKey;
            more = page.hasMore;
            await serialize(async () => save({
              ...state,
              migration: {
                ...state.migration,
                [field]: more ? after : '__complete__'
              }
            }));
          }
        }
        await rpc('reader_delta_finish_migration', {
          p_manifest: manifest
        });
        return manifest;
      },
      materialize() {
        observed = structuredClone(state.entities);
        const result = {
          vocabulary: [],
          favorites: [],
          reading_positions: {},
          quiz_progress: {},
          completion_records: {},
          preferences: {},
          encrypted_ai_key: null
        };
        for (const e of Object.values(state.entities)) {
          if (e.deleted) continue;
          const {
            entityType: t,
            entityID: id,
            payload: p
          } = e;
          if (['reading_positions', 'completion_records', 'preferences'].includes(t)) result[t][id] = p;else if (t === 'favorite') result.favorites.push(id);else if (t === 'vocabulary') result.vocabulary.push(p);else if (t === 'encrypted_ai_key') result.encrypted_ai_key = p;else if (t === 'quiz_meta') result.quiz_progress[id] = {
            ...result.quiz_progress[id],
            ...p
          };else if (t.startsWith('quiz_')) {
            const [article, q] = JSON.parse(id),
              field = t.slice(5);
            const progress = result.quiz_progress[article] ||= {};
            (progress[field] ||= {})[q] = p;
          }
        }
        return result;
      },
      close() {
        db?.close();
      }
    };
    return api;
  };
  function acksLength(result) {
    return (result.acknowledgements || result.acks || []).length;
  }
})(typeof window === 'undefined' ? globalThis : window);
