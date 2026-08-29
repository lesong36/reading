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
    const html = `<h1>今日学习报告 · ${localDate}</h1><ul><li>完成阅读：${counts.article_completed || 0} 篇</li><li>交卷：${counts.quiz_submitted || 0} 次</li><li>新增生词：${counts.vocab_added || 0} 个</li><li>AI 证据评测：${counts.quiz_evaluated || 0} 次</li><li>待人工校验：${counts.answer_review_requested || 0} 个</li></ul><p><a href="${appUrl}">查看完整每日记录</a></p>`;
    const resend = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ from: reportFrom, to: [email], subject: `每日学习报告 · ${localDate}`, html }) });
    if (!resend.ok) { await admin.from('daily_report_deliveries').update({ status: 'failed', error_message: (await resend.text()).slice(0, 500), updated_at: new Date().toISOString() }).eq('id', claimed.id); continue; }
    const body = await resend.json();
    await admin.from('daily_report_deliveries').update({ status: 'sent', provider_message_id: body.id || null, sent_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq('id', claimed.id);
    outcome.push(state.user_id);
  }
  return Response.json({ sent: outcome.length });
});
