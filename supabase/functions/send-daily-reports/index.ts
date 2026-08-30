import { createClient } from 'npm:@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const resendKey = Deno.env.get('RESEND_API_KEY')!;
const reportFrom = Deno.env.get('DAILY_REPORT_FROM')!;
const cronSecret = Deno.env.get('DAILY_REPORT_CRON_SECRET')!;
const appUrl = Deno.env.get('DAILY_REPORT_APP_URL') || 'https://lesong36.github.io/reading/';
const admin = createClient(supabaseUrl, serviceRoleKey);

const dayForZoneAt = (timezone: string, at = new Date()) => {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(at);
  const value = Object.fromEntries(parts.filter(part => part.type !== 'literal').map(part => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
};
const dayForZone = (timezone: string) => dayForZoneAt(timezone);
const hourMinuteForZone = (timezone: string) => new Intl.DateTimeFormat('en-GB', { timeZone: timezone, hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date());
const escapeHtml = (value: unknown) => String(value ?? '').replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]!));
const answerLabel = (options: unknown, index: unknown) => {
  const items = Array.isArray(options) ? options : [];
  return Number.isInteger(index) && items[index as number] ? `${String.fromCharCode(65 + (index as number))}. ${items[index as number]}` : '未作答';
};
const locatorStatusLabel = (value: unknown) => ({ valid: '定位有效', partial: '定位部分有效', invalid: '定位不成立', missing: '未提供定位句' }[String(value)] || '未评测');
const referenceStatusLabel = (value: unknown) => ({ supported: '参考答案可被支持', questionable: '参考答案存在疑点', insufficient: '证据不足以确认参考答案' }[String(value)] || '未评测');
const renderQuizEvaluation = (event: Record<string, any>) => {
  const payload = event.payload || {};
  const locatorWindow = Array.isArray(payload.locatorWindow) ? payload.locatorWindow : [];
  const evidence = new Set(Array.isArray(payload.evidenceSentenceIds) ? payload.evidenceSentenceIds : []);
  const locator = locatorWindow.find((sentence: Record<string, unknown>) => sentence.id === payload.locatorSentenceId);
  const locatorLines = locatorWindow.length
    ? locatorWindow.map((sentence: Record<string, unknown>) => `<li style="margin:4px 0;${sentence.id === payload.locatorSentenceId ? 'font-weight:700;' : ''}">${sentence.id === payload.locatorSentenceId ? '定位句：' : ''}${escapeHtml(sentence.text)}${evidence.has(sentence.id) ? ' <span style="color:#4f46e5">（AI 证据）</span>' : ''}</li>`).join('')
    : '<li>本题未点选定位句。</li>';
  const question = payload.questionPrompt ? `<p style="margin:8px 0"><b>题目：</b>${escapeHtml(payload.questionPrompt)}</p>` : '<p style="margin:8px 0"><b>题目：</b>旧记录未保存题干；请在应用内查看本题。</p>';
  const locatorSummary = locator ? escapeHtml(locator.text) : '未点选定位句';
  return `<section style="margin:18px 0;padding:16px;border:1px solid #dbeafe;border-radius:12px;background:#f8fbff"><h2 style="font-size:16px;margin:0">${escapeHtml(event.article_title || '阅读文章')} · 第 ${escapeHtml(String(event.question_id || '—'))} 题</h2>${question}<p style="margin:8px 0"><b>你的选择：</b>${escapeHtml(answerLabel(payload.options, payload.learnerAnswerIndex))}</p><p style="margin:8px 0"><b>参考答案（候选）：</b>${escapeHtml(answerLabel(payload.options, payload.referenceAnswerIndex))}</p><p style="margin:8px 0"><b>你点选的定位句：</b>${locatorSummary}</p><details style="margin:8px 0"><summary>查看定位句上下文（前后两句）</summary><ol style="padding-left:20px">${locatorLines}</ol></details><p style="margin:8px 0"><b>AI 判断：</b>${escapeHtml(referenceStatusLabel(payload.referenceAnswerVerdict))}；${escapeHtml(locatorStatusLabel(payload.locatorVerdict))}</p><p style="margin:8px 0"><b>理由：</b>${escapeHtml(payload.reasoning || '模型未提供文字理由。')}</p>${payload.disputed ? '<p style="margin:8px 0;color:#be123c;font-weight:700">已标记为待人工校验；系统不会自动改写官方答案。</p>' : ''}</section>`;
};

Deno.serve(async (request) => {
  if (request.headers.get('x-daily-report-secret') !== cronSecret) return new Response('Unauthorized', { status: 401 });
  const { data: states, error } = await admin.from('reader_sync_state').select('user_id,preferences');
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const outcome: string[] = [];
  for (const state of states || []) {
    const setting = state.preferences?.dailyReport;
    if (!setting?.enabled) continue;
    const timezone = setting.timezone || 'Asia/Shanghai';
    const localTime = hourMinuteForZone(timezone);
    if (localTime < (setting.time || '20:30') || localTime > `${setting.time || '20:30'}`.replace(/:(\d\d)$/, (_, minutes) => `:${String(Math.min(59, Number(minutes) + 9)).padStart(2, '0')}`)) continue;
    const localDate = dayForZone(timezone);
    const { data: claimed } = await admin.from('daily_report_deliveries').upsert({ user_id: state.user_id, local_date: localDate, timezone, status: 'sending' }, { onConflict: 'user_id,local_date', ignoreDuplicates: true }).select('id').maybeSingle();
    if (!claimed) continue;
    const since = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
    const { data: recentEvents } = await admin.from('learning_events').select('event_type,payload,article_title,occurred_at').eq('user_id', state.user_id).gte('occurred_at', since);
    const events = (recentEvents || []).filter(event => dayForZoneAt(timezone, new Date(event.occurred_at)) === localDate);
    if (!events.length) { await admin.from('daily_report_deliveries').update({ status: 'skipped', updated_at: new Date().toISOString() }).eq('id', claimed.id); continue; }
    const { data: auth } = await admin.auth.admin.getUserById(state.user_id);
    const email = auth.user?.email;
    if (!email) { await admin.from('daily_report_deliveries').update({ status: 'failed', error_message: 'No verified Auth email', updated_at: new Date().toISOString() }).eq('id', claimed.id); continue; }
    const counts = events.reduce((result: Record<string, number>, event) => ({ ...result, [event.event_type]: (result[event.event_type] || 0) + 1 }), {});
    const evaluations = events.filter(event => event.event_type === 'quiz_evaluated');
    const quizDetails = evaluations.length
      ? `<h2 style="font-size:18px;margin-top:28px">做题与 AI 评测</h2>${evaluations.map(renderQuizEvaluation).join('')}`
      : '<p style="color:#64748b">今天没有完成 AI 证据评测的题目；交卷记录仍会在应用的每日记录页保留。</p>';
    const html = `<main style="max-width:680px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#172033"><h1>今日学习报告 · ${localDate}</h1><ul><li>完成阅读：${counts.article_completed || 0} 篇</li><li>作答：${counts.quiz_answered || 0} 题（已交卷 ${counts.quiz_submitted || 0} 次）</li><li>新增生词：${counts.vocab_added || 0} 个</li><li>AI 证据评测：${counts.quiz_evaluated || 0} 次</li><li>待人工校验：${counts.answer_review_requested || 0} 个</li></ul>${quizDetails}<p style="margin-top:24px"><a href="${escapeHtml(appUrl)}">查看完整每日记录</a></p></main>`;
    const resend = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ from: reportFrom, to: [email], subject: `每日学习报告 · ${localDate}`, html }) });
    if (!resend.ok) { await admin.from('daily_report_deliveries').update({ status: 'failed', error_message: (await resend.text()).slice(0, 500), updated_at: new Date().toISOString() }).eq('id', claimed.id); continue; }
    const body = await resend.json();
    await admin.from('daily_report_deliveries').update({ status: 'sent', provider_message_id: body.id || null, sent_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', claimed.id);
    outcome.push(state.user_id);
  }
  return Response.json({ sent: outcome.length });
});
