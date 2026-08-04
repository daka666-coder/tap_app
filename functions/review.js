// Cloudflare Pages Function: /review
//
// 為什麼需要這個檔案：
// TapApp 的核准/駁回信件連結原本直接指向 script.google.com/macros/s/.../exec。
// 手機若登入多個 Google 帳號，Gmail App 點連結時會自動幫 google.com 網域的網址
// 加上 /u/{帳號索引}/，但 Apps Script 的 /exec 網址不支援這種路徑，一律回應
// 「找不到網頁」（即使匿名測試也一樣，屬於 Apps Script /exec 端點本身的限制）。
//
// 解法：信件裡改放這支 Function 的網址（daka-2cm.pages.dev/review，非 google.com
// 網域），Gmail 不會對它做帳號改寫；實際請求在這裡於伺服器端轉發給 Apps Script，
// 瀏覽器網址列全程停留在我們自己的網域。

const EXEC_URL =
  'https://script.google.com/macros/s/AKfycbxlIn937AiI5m92HM1y9DzIvBsAfisFGDinLkTh3wAe0noKBUqfCRjbIgW3a5HLbb12/exec';

function escapeHtml(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function htmlPage(bodyHtml) {
  return new Response(
    `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width, initial-scale=1">` +
      `<title>TapApp 簽核</title></head>` +
      `<body style="font-family:system-ui;padding:16px;">${bodyHtml}</body></html>`,
    { headers: { 'content-type': 'text/html; charset=utf-8' } }
  );
}

async function proxyToExec(params) {
  const target = `${EXEC_URL}?${params.toString()}`;
  const resp = await fetch(target, { redirect: 'follow' });
  const text = await resp.text();
  return new Response(text, { headers: { 'content-type': 'text/html; charset=utf-8' } });
}

export async function onRequestGet({ request }) {
  const url = new URL(request.url);
  const action = (url.searchParams.get('action') || '').trim();
  const reqId = (url.searchParams.get('reqId') || '').trim();
  const token = (url.searchParams.get('token') || '').trim();

  if (!reqId || !token) {
    return htmlPage('<p>連結缺少必要參數，請重新從信件中的連結開啟。</p>');
  }

  if (action === 'approve') {
    return proxyToExec(new URLSearchParams({ action: 'approve', reqId, token }));
  }

  if (action === 'reject') {
    const body = `
      <div style="max-width:480px;margin:0 auto;">
        <h3>駁回補打卡申請</h3>
        <p>單號：${escapeHtml(reqId)}</p>
        <form method="GET" action="/review">
          <input type="hidden" name="action" value="rejectSubmit">
          <input type="hidden" name="reqId" value="${escapeHtml(reqId)}">
          <input type="hidden" name="token" value="${escapeHtml(token)}">
          <label for="rejectReason">拒絕原因：</label><br>
          <textarea id="rejectReason" name="rejectReason" rows="4"
            style="width:100%;box-sizing:border-box;margin-top:6px;" required></textarea>
          <br><br>
          <button type="submit" style="padding:8px 20px;font-size:14px;">確認駁回</button>
        </form>
      </div>`;
    return htmlPage(body);
  }

  if (action === 'rejectSubmit') {
    const rejectReason = url.searchParams.get('rejectReason') || '';
    return proxyToExec(new URLSearchParams({ action: 'rejectSubmit', reqId, token, rejectReason }));
  }

  return htmlPage('<p>未知的操作。</p>');
}
