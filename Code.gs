/**
 * ✅ Tap App Web API - 修正版（可直接整份貼上）
 * - 修正：exceptionRequest 寫入時 ReferenceError: headers is not defined
 * - 修正：避免重複宣告 getOrCreateExceptionSheet_ 造成覆蓋
 * - 強化：Exception_Requests 表頭自動補齊 + 可選擇強制重排（本版預設 true）
 * - 新增：例外申請可記錄補上班卡/補下班卡與指定補卡時間
 * - 新增：核准補卡時與當日既有打卡合併，保留另一端正確時間
 * - 新增：主管駁回時可填寫拒絕原因（點擊駁回連結 → 小表單 → 送出）
 * - 新增：員工登入時查詢「被拒絕且尚未看過」的補打卡申請並顯示原因
 * - 保留：打卡 punch、dayPunch、approve/reject、WorkHour_Check、日期時間解析、清洗工具
 *
 * Sheets required (auto-create if missing where applicable):
 * - Employee_Master
 * - Shift_Template
 * - Weekly_Schedule
 * - GeoFence_Points
 * - Punch_Log
 * - Exception_Requests
 * - Settings (key,value) -> supervisorEmail, supervisorEmpIds
 * - WorkHour_Check
 */

const SPREADSHEET_ID = '1tYL6JvV-2qg1PcR1NvM4UQf17EV36IpngFgfLV8BnWI';

const SHEET_EMP = 'Employee_Master';
const SHEET_SHIFT = 'Shift_Template';
const SHEET_ROSTER = 'Weekly_Schedule';
const SHEET_GEOFENCE = 'GeoFence_Points';
const SHEET_PUNCH = 'Punch_Log';
const SHEET_EXC = 'Exception_Requests';
const SHEET_SETTINGS = 'Settings';
const SHEET_WORKHOUR = 'WorkHour_Check';

const PROP_SECRET_KEY = 'TAPAPP_SECRET';
const TZ = 'Asia/Taipei';

// ✅ 每次修改 Code.gs 並部署新版本時同步更新，方便用 GET /exec 直接確認雲端是否已套用最新程式碼
const SCRIPT_VERSION = 'v2026.08.04+cloudflareReviewProxy';

// ✅ 核准/駁回信件連結改走 Cloudflare（非 google.com 網域）。
// 原因：手機多帳號時，Gmail App 點連結會自動幫 script.google.com 網址加上 /u/{n}/，
// 但 Apps Script 的 /exec 網址不支援這種路徑格式，一律回應「找不到網頁」。
// Cloudflare Pages Function（tap_app/functions/review.js）收到請求後在伺服器端轉發給這支 /exec，
// 瀏覽器網址列全程停留在 daka-2cm.pages.dev，不會被 Gmail 改寫。
const REVIEW_PROXY_URL = 'https://daka-2cm.pages.dev/review';

/* ===================== Entry ===================== */

function doGet(e) {
  try {
    const action = (e && e.parameter && e.parameter.action) ? String(e.parameter.action).trim() : '';

    if (!action) {
      return jsonOut({ ok: true, msg: 'Tap App API - GET OK', version: SCRIPT_VERSION, timestamp: new Date().toISOString() });
    }

    if (action === 'data') {
      const employees = getEmployees_();
      const shifts = getShifts_();
      const roster = getRoster_();
      const geofencePoints = getGeoFencePoints_();
      return jsonOut({ ok: true, employees, shifts, roster, geofencePoints });
    }

    if (action === 'dayPunch') {
      const empId = (e.parameter.empId || '').toString().trim();
      const date = (e.parameter.date || '').toString().trim();
      if (!empId) return jsonOut({ ok: false, error: 'Missing empId' });
      if (!date) return jsonOut({ ok: false, error: 'Missing date' });

      const result = getDayPunchFromLog_(empId, date);
      return jsonOut({ ok: true, ...result });
    }

    // ✅ 主管點擊 Email 核准連結：直接核准
    if (action === 'approve') {
      const reqId = (e.parameter.reqId || '').toString().trim();
      const token = (e.parameter.token || '').toString().trim();
      if (!reqId) return htmlOut_('Missing reqId');
      if (!token) return htmlOut_('Missing token');

      const ok = verifyToken_(reqId, token);
      if (!ok) return htmlOut_('Invalid token');

      const result = handleApproval_(reqId, 'APPROVED');
      return htmlOut_(result);
    }

    // ✅ 主管點擊 Email 駁回連結：先顯示小表單，讓主管填寫拒絕原因
    if (action === 'reject') {
      const reqId = (e.parameter.reqId || '').toString().trim();
      const token = (e.parameter.token || '').toString().trim();
      if (!reqId) return htmlOut_('Missing reqId');
      if (!token) return htmlOut_('Missing token');

      const ok = verifyToken_(reqId, token);
      if (!ok) return htmlOut_('Invalid token');

      return rejectFormOut_(reqId, token);
    }

    // ✅ 主管在駁回表單填完原因後送出：真正寫入駁回狀態與原因
    if (action === 'rejectSubmit') {
      const reqId = (e.parameter.reqId || '').toString().trim();
      const token = (e.parameter.token || '').toString().trim();
      const rejectReason = (e.parameter.rejectReason || '').toString().trim();
      if (!reqId) return htmlOut_('Missing reqId');
      if (!token) return htmlOut_('Missing token');

      const ok = verifyToken_(reqId, token);
      if (!ok) return htmlOut_('Invalid token');

      const result = handleApproval_(reqId, 'REJECTED', rejectReason);
      return htmlOut_(result);
    }

    // ✅ 員工查詢：自己是否有「被拒絕且尚未看過」的補打卡申請
    if (action === 'myExceptionStatus') {
      const empId = (e.parameter.empId || '').toString().trim();
      const pin = (e.parameter.pin || '').toString().trim();
      if (!empId) return jsonOut({ ok: false, error: 'Missing empId' });
      if (!pin) return jsonOut({ ok: false, error: 'Missing pin' });

      try {
        const data = getMyRejectedNotice_(empId, pin);
        return jsonOut({ ok: true, data });
      } catch (err) {
        return jsonOut({ ok: false, error: String(err && err.message ? err.message : err) });
      }
    }

    return jsonOut({ ok: false, error: 'Unknown action: ' + action });
  } catch (err) {
    Logger.log('doGet Error: ' + err);
    return jsonOut({ ok: false, error: String(err) });
  }
}

function doPost(e) {
  try {
    const payload = parseBody_(e);
    const action = String(payload.action || '').trim();

    if (action === 'punch') return handlePunch_(payload);
    if (action === 'exceptionRequest') return handleExceptionRequest_(payload);

    // ✅ 員工已看過拒絕通知，標記已讀（避免下次登入重複跳出）
    if (action === 'ackException') {
      try {
        const data = ackExceptionSeen_(payload);
        return jsonOut({ ok: true, data });
      } catch (err) {
        return jsonOut({ ok: false, error: String(err && err.message ? err.message : err) });
      }
    }

    return jsonOut({ ok: false, error: 'Invalid action: ' + action });
  } catch (err) {
    Logger.log('doPost Error: ' + err);
    return jsonOut({ ok: false, error: String(err) });
  }
}

/* ===================== Handlers ===================== */

function handlePunch_(payload) {
  const empId = String(payload.empId || '').trim();
  const empName = String(payload.empName || '').trim();
  const pin = String(payload.pin || '').trim();
  const date = String(payload.date || '').trim();

  const firstPunchRaw = payload.firstPunch;
  const lastPunchRaw = payload.lastPunch;

  const source = String(payload.source || '').trim();
  const userAgent = String(payload.userAgent || '').trim();

  const lat = payload.lat;
  const lng = payload.lng;
  const accuracyM = payload.accuracyM;

  if (!empId || !date || firstPunchRaw === undefined || lastPunchRaw === undefined) {
    return jsonOut({ ok: false, error: 'Missing required fields (empId/date/firstPunch/lastPunch)' });
  }
  if (!pin) return jsonOut({ ok: false, error: 'Missing pin' });
  if (lat === undefined || lng === undefined || accuracyM === undefined) {
    return jsonOut({ ok: false, error: 'Missing GPS fields (lat/lng/accuracyM)' });
  }

  const emp = getEmployeeById_(empId);
  if (!emp) return jsonOut({ ok: false, error: 'Employee not found: ' + empId });

  const empPin = String(emp.pin || '').trim();
  if (!empPin) return jsonOut({ ok: false, error: 'Employee pin not set. Please contact admin.' });
  if (empPin !== pin) return jsonOut({ ok: false, error: 'PIN verification failed' });

  const geo = checkGeoFence_(Number(lat), Number(lng));
  if (!geo.allowed) {
    return jsonOut({
      ok: false,
      error: 'Out of allowed range',
      nearestName: geo.nearestName,
      nearestDistanceM: geo.nearestDistanceM,
      nearestRadiusM: geo.nearestRadiusM,
    });
  }

  const safeEmpName = emp.empName ? String(emp.empName).trim() : empName;

  const firstPunchDt = parsePunchDateTime_(date, firstPunchRaw);
  const lastPunchDt = parsePunchDateTime_(date, lastPunchRaw);
  if (!firstPunchDt || !lastPunchDt) {
    return jsonOut({ ok: false, error: 'Invalid punch datetime format (firstPunch/lastPunch)' });
  }

  appendPunch_({
    empId,
    empName: safeEmpName,
    date,
    firstPunch: firstPunchDt,
    lastPunch: lastPunchDt,
    source,
    userAgent,
    lat: Number(lat),
    lng: Number(lng),
    accuracyM: Number(accuracyM),
    approvedBy: '',
    exceptionReason: '',
    status: 'NORMAL',
  });

  updateWorkHourCheck_(empId, date);

  return jsonOut({ ok: true, message: 'Punch recorded successfully', empId, date });
}

/**
 * ✅ 例外補卡申請（寫入 Exception_Requests，並寄出簽核信）
 * ✅ 本版重點修正：headers / index 未定義造成 ReferenceError
 */
function handleExceptionRequest_(payload) {
  const empId = String(payload.empId || '').trim();
  const empName = String(payload.empName || '').trim();
  const pin = String(payload.pin || '').trim();
  const date = String(payload.date || '').trim();
  const firstPunch = payload.firstPunch;
  const lastPunch = payload.lastPunch;
  const punchType = normalizePunchType_(payload.punchType);
  const requestedPunchAtRaw = payload.requestedPunchAt;
  const reason = String(payload.reason || '').trim();
  const source = String(payload.source || '').trim();
  const userAgent = String(payload.userAgent || '').trim();

  if (!empId || !date || firstPunch === undefined || lastPunch === undefined) {
    return jsonOut({ ok: false, error: 'Missing required fields (empId/date/firstPunch/lastPunch)' });
  }
  if (!pin) return jsonOut({ ok: false, error: 'Missing pin' });
  if (!reason) return jsonOut({ ok: false, error: 'Missing reason' });

  // 新版 App 會同時傳 punchType 與 requestedPunchAt；兩者必須成對出現。
  // 舊版 App 兩者都未傳時，仍沿用 firstPunch/lastPunch，避免既有打卡流程中斷。
  const hasNewMakeupFields =
    payload.punchType !== undefined || requestedPunchAtRaw !== undefined;
  if (hasNewMakeupFields && !punchType) {
    return jsonOut({ ok: false, error: 'Invalid punchType (CLOCK_IN/CLOCK_OUT)' });
  }
  if (hasNewMakeupFields && (requestedPunchAtRaw === undefined || requestedPunchAtRaw === null || String(requestedPunchAtRaw).trim() === '')) {
    return jsonOut({ ok: false, error: 'Missing requestedPunchAt' });
  }

  const emp = getEmployeeById_(empId);
  if (!emp) return jsonOut({ ok: false, error: 'Employee not found: ' + empId });

  const empPin = String(emp.pin || '').trim();
  if (!empPin) return jsonOut({ ok: false, error: 'Employee pin not set. Please contact admin.' });
  if (empPin !== pin) return jsonOut({ ok: false, error: 'PIN verification failed' });

  const safeEmpName = emp.empName ? String(emp.empName).trim() : empName;
  if (!safeEmpName) return jsonOut({ ok: false, error: 'Employee name is missing' });

  const reqId = 'REQ-' + Utilities.getUuid();
  const token = makeToken_(reqId);

  // ✅ 確保 date 是 yyyy-MM-dd 格式
  const normalizedDate = normalizeDate_(date);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(normalizedDate)) {
    return jsonOut({ ok: false, error: 'Invalid date' });
  }

  const requestedPunchAt = hasNewMakeupFields
    ? parsePunchDateTime_(normalizedDate, requestedPunchAtRaw)
    : null;
  if (hasNewMakeupFields && !requestedPunchAt) {
    return jsonOut({ ok: false, error: 'Invalid requestedPunchAt' });
  }
  if (requestedPunchAt && requestedPunchAt.getTime() > Date.now() + 60 * 1000) {
    return jsonOut({ ok: false, error: 'requestedPunchAt cannot be in the future' });
  }
  if (requestedPunchAt && normalizeDate_(requestedPunchAt) !== normalizedDate) {
    return jsonOut({ ok: false, error: 'requestedPunchAt date does not match date' });
  }

  // ✅ 取得表 & 確保表頭（forceReorder=true：統一欄位順序，避免又被拖歪）
  const sh = getOrCreateExceptionSheet_();
  const info = ensureExceptionRequestHeaders_(sh, true);

  const headers = info.headers;
  const map = info.map;

  const idx = (name) => (map[name] === undefined ? -1 : map[name]);

  const iTimestamp = idx('timestamp');
  const iReqId = idx('reqId');
  const iStatus = idx('status');
  const iEmpId = idx('empId');
  const iEmpName = idx('empName');
  const iDate = idx('date');
  const iPunchType = idx('punchType');
  const iRequestedPunchAt = idx('requestedPunchAt');
  const iFirst = idx('firstPunch');
  const iLast = idx('lastPunch');
  const iReason = idx('reason');
  const iSource = idx('source');
  const iUA = idx('userAgent');
  const iToken = idx('token');
  const iRejectReason = idx('rejectReason');
  const iEmpSeenAt = idx('empSeenAt');

  const row = new Array(headers.length).fill('');

  if (iTimestamp >= 0) row[iTimestamp] = new Date();
  if (iReqId >= 0) row[iReqId] = reqId;
  if (iStatus >= 0) row[iStatus] = 'PENDING';
  if (iEmpId >= 0) row[iEmpId] = empId;
  if (iEmpName >= 0) row[iEmpName] = safeEmpName;
  if (iDate >= 0) row[iDate] = normalizedDate;
  if (iPunchType >= 0) row[iPunchType] = punchType;
  if (iRequestedPunchAt >= 0) row[iRequestedPunchAt] = requestedPunchAt || '';
  if (iFirst >= 0) row[iFirst] = String(firstPunch || '').trim();
  if (iLast >= 0) row[iLast] = String(lastPunch || '').trim();
  if (iReason >= 0) row[iReason] = reason;
  if (iSource >= 0) row[iSource] = source;
  if (iUA >= 0) row[iUA] = userAgent;
  if (iToken >= 0) row[iToken] = token;
  if (iRejectReason >= 0) row[iRejectReason] = '';
  if (iEmpSeenAt >= 0) row[iEmpSeenAt] = '';

  sh.appendRow(row);

  // ✅ 寄出主管簽核信
  const supervisorEmail = getSupervisorEmail_();
  if (supervisorEmail) {
    const approveUrl = buildApproveUrl_(reqId, token, 'approve');
    const rejectUrl = buildApproveUrl_(reqId, token, 'reject');

    const punchTypeLabel = punchTypeLabel_(punchType);
    const requestedPunchText = requestedPunchAt
      ? Utilities.formatDate(requestedPunchAt, TZ, 'yyyy-MM-dd HH:mm')
      : '舊版申請（未指定單一補卡時間）';

    const subject = `[TapApp] 例外補卡簽核：${safeEmpName}（${empId}）${normalizedDate}`;
    const body =
      `您有一筆 TapApp 例外補卡申請待簽核：\n\n` +
      `員工：${safeEmpName}（${empId}）\n` +
      `日期：${normalizedDate}\n` +
      `補卡類型：${punchTypeLabel}\n` +
      `申請補卡時間：${requestedPunchText}\n` +
      `首次：${String(firstPunch || '').trim()}\n` +
      `最後：${String(lastPunch || '').trim()}\n` +
      `原因：${reason}\n` +
      `來源：${source}\n\n` +
      `核准：${approveUrl}\n` +
      `駁回：${rejectUrl}\n\n` +
      `（本信由系統自動寄送）`;

    MailApp.sendEmail(supervisorEmail, subject, body);
  }

  return jsonOut({
    ok: true,
    message: 'Exception request submitted for approval',
    reqId,
    punchType,
    requestedPunchAt: requestedPunchAt ? requestedPunchAt.toISOString() : null,
  });
}

/* ===================== Approval ===================== */

function handleApproval_(reqId, decision, rejectReason) {
  const sh = getOrCreateExceptionSheet_();
  const values = sh.getDataRange().getValues();
  if (values.length < 2) return 'No requests';

  const headers = values[0].map(h => String(h || '').trim());
  const idx = (name) => headers.indexOf(name);

  const iReq = idx('reqId');
  const iStatus = idx('status');
  const iEmpId = idx('empId');
  const iEmpName = idx('empName');
  const iDate = idx('date');
  const iPunchType = idx('punchType');
  const iRequestedPunchAt = idx('requestedPunchAt');
  const iFirst = idx('firstPunch');
  const iLast = idx('lastPunch');
  const iReason = idx('reason');
  const iRejectReason = idx('rejectReason');
  const iEmpSeenAt = idx('empSeenAt');
  const iReviewedBy = idx('reviewedBy');
  const iReviewedAt = idx('reviewedAt');

  if (iReq < 0) return 'Sheet Exception_Requests missing column: reqId';
  if (iStatus < 0) return 'Sheet Exception_Requests missing column: status';

  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    if (String(row[iReq] || '').trim() !== reqId) continue;

    const currentStatus = String(row[iStatus] || '').trim();
    if (currentStatus !== 'PENDING') return `This request is already processed: ${currentStatus}`;

    if (decision === 'APPROVED') {
      let empIdRaw = String(row[iEmpId] || '').trim();
      let empNameRaw = String(row[iEmpName] || '').trim();
      const dateRaw = row[iDate];

      const date = normalizeDate_(dateRaw);
      if (!date) return '❌ 核准失敗：日期格式無效';

      // ✅ 防錯：empId/empName 若被寫反，嘗試修正
      let empId = empIdRaw;
      let empName = empNameRaw;

      const empIdLooksLikeName = /[一-龥]/.test(empIdRaw);
      if (empIdLooksLikeName) {
        const emp = getEmployeeByName_(empIdRaw);
        if (emp) {
          empId = emp.empId;
          empName = emp.empName;
        } else {
          const emp2 = getEmployeeById_(empNameRaw);
          if (emp2) {
            empId = emp2.empId;
            empName = emp2.empName;
          } else {
            return `❌ 核准失敗：無法從員工主檔找到「${empIdRaw}」或「${empNameRaw}」的對應資料`;
          }
        }
      } else {
        const emp = getEmployeeById_(empId);
        if (emp) {
          empId = emp.empId;
          empName = emp.empName;
        } else {
          return `❌ 核准失敗：員工編號「${empId}」不存在於員工主檔`;
        }
      }

      if (!empId) return '❌ 核准失敗：員工編號 (empId) 遺失';
      if (!empName) return '❌ 核准失敗：員工姓名 (empName) 遺失';

      const punchType = iPunchType >= 0
        ? normalizePunchType_(row[iPunchType])
        : '';
      const requestedPunchAt = iRequestedPunchAt >= 0
        ? parsePunchDateTime_(date, row[iRequestedPunchAt])
        : null;

      let firstDt;
      let lastDt;

      if (punchType && requestedPunchAt) {
        // 新版補卡：先讀取該員工當日既有打卡，再只替換申請的一端。
        // 補上班卡保留既有最後打卡；補下班卡保留既有首次打卡。
        const existing = getDayPunchFromLog_(empId, date);
        const existingFirst = parsePunchDateTime_(date, existing.firstPunch);
        const existingLast = parsePunchDateTime_(date, existing.lastPunch);

        if (punchType === 'CLOCK_IN') {
          firstDt = requestedPunchAt;
          lastDt = existingLast || requestedPunchAt;
        } else {
          firstDt = existingFirst || requestedPunchAt;
          lastDt = requestedPunchAt;
        }
      } else {
        // 舊版相容：沿用原有 firstPunch/lastPunch。
        firstDt = parsePunchDateTime_(date, row[iFirst]);
        lastDt = parsePunchDateTime_(date, row[iLast]);
      }

      if (!firstDt || !lastDt) return '❌ 核准失敗：例外申請的時間格式無法解析（firstPunch/lastPunch）';
      if (lastDt.getTime() < firstDt.getTime()) {
        return '❌ 核准失敗：下班時間早於上班時間，請駁回後重新申請';
      }

      appendPunch_({
        empId,
        empName,
        date,
        firstPunch: firstDt,
        lastPunch: lastDt,
        source: 'exception',
        userAgent: '',
        lat: '',
        lng: '',
        accuracyM: '',
        approvedBy: 'SUPERVISOR',
        exceptionReason:
          `${punchTypeLabel_(punchType)} ${requestedPunchAt
            ? Utilities.formatDate(requestedPunchAt, TZ, 'yyyy-MM-dd HH:mm') + '；'
            : ''}${String(row[iReason] || '').trim()}`.trim(),
        status: 'APPROVED_EXCEPTION',
      });

      updateWorkHourCheck_(empId, date);

      // 所有核准資料均成功寫入後，才更新申請狀態，避免失敗案件被誤標為已核准。
      sh.getRange(r + 1, iStatus + 1).setValue('APPROVED');
      writeReviewMeta_(sh, r + 1, iReviewedBy, iReviewedAt);

      return '✅ 已核准並寫入 Punch_Log（可關閉本頁）';
    }

    // ✅ REJECTED：寫入拒絕原因，並清空 empSeenAt 讓員工下次登入能收到通知
    if (iRejectReason >= 0) sh.getRange(r + 1, iRejectReason + 1).setValue(rejectReason || '');
    if (iEmpSeenAt >= 0) sh.getRange(r + 1, iEmpSeenAt + 1).setValue('');
    sh.getRange(r + 1, iStatus + 1).setValue('REJECTED');
    writeReviewMeta_(sh, r + 1, iReviewedBy, iReviewedAt);
    return '✅ 已駁回（可關閉本頁）';
  }

  return 'Request not found';
}

// ✅ 找出該員工「已被拒絕、且員工還沒看過」的最新一筆申請
function getMyRejectedNotice_(empId, pin) {
  const emp = getEmployeeById_(empId);
  if (!emp) throw new Error('Employee not found: ' + empId);

  const empPin = String(emp.pin || '').trim();
  if (!empPin) throw new Error('Employee pin not set. Please contact admin.');
  if (empPin !== String(pin || '').trim()) throw new Error('PIN verification failed');

  const rows = readSheetAsObjects_(SHEET_EXC);
  const candidates = rows.filter(r =>
    String(r.status || '').trim() === 'REJECTED' &&
    String(r.empId || '').trim() === String(empId).trim() &&
    String(r.empSeenAt || '').trim() === ''
  );
  if (candidates.length === 0) return null;

  candidates.sort((a, b) => {
    const ta = a.timestamp instanceof Date ? a.timestamp.getTime() : new Date(a.timestamp || 0).getTime();
    const tb = b.timestamp instanceof Date ? b.timestamp.getTime() : new Date(b.timestamp || 0).getTime();
    return tb - ta;
  });

  const top = candidates[0];
  return {
    requestId: String(top.reqId || ''),
    date: normalizeDate_(top.date),
    rejectReason: String(top.rejectReason || ''),
  };
}

// ✅ 員工已讀該筆拒絕通知
function ackExceptionSeen_(body) {
  const reqId = String(body.reqId || body.requestId || '').trim();
  if (!reqId) throw new Error('Missing reqId');

  const empId = String(body.empId || '').trim();
  const pin = String(body.pin || '').trim();
  if (empId && pin) {
    const emp = getEmployeeById_(empId);
    if (!emp) throw new Error('Employee not found: ' + empId);
    if (String(emp.pin || '').trim() !== pin) throw new Error('PIN verification failed');
  }

  const sh = getOrCreateExceptionSheet_();
  const values = sh.getDataRange().getValues();
  const headers = values[0].map(h => String(h || '').trim());
  const iReq = headers.indexOf('reqId');
  const iSeen = headers.indexOf('empSeenAt');
  if (iReq < 0 || iSeen < 0) throw new Error('Exception_Requests missing reqId/empSeenAt column');

  for (let r = 1; r < values.length; r++) {
    if (String(values[r][iReq] || '').trim() === reqId) {
      sh.getRange(r + 1, iSeen + 1).setValue(new Date());
      return { requestId: reqId, acked: true };
    }
  }
  throw new Error('Request not found: ' + reqId);
}

// ✅ 核准/駁回時寫入審核主管身分(empId)與審核時間，留下簽核軌跡
function writeReviewMeta_(sh, rowNum, iReviewedBy, iReviewedAt) {
  const supervisorEmpId = getSupervisorEmpId_();
  if (iReviewedBy >= 0) sh.getRange(rowNum, iReviewedBy + 1).setValue(supervisorEmpId);
  if (iReviewedAt >= 0) {
    const reviewedAtText = Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd HH:mm:ss');
    sh.getRange(rowNum, iReviewedAt + 1).setValue(reviewedAtText).setNumberFormat('@');
  }
}

function verifyToken_(reqId, token) {
  const expected = makeToken_(reqId);
  return String(expected) === String(token);
}

function makeToken_(reqId) {
  const secret = getOrInitSecret_();
  const raw = reqId + '|' + secret;
  const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, raw);
  return Utilities.base64EncodeWebSafe(bytes).substring(0, 24);
}

function buildApproveUrl_(reqId, token, action) {
  return `${REVIEW_PROXY_URL}?action=${action}&reqId=${encodeURIComponent(reqId)}&token=${encodeURIComponent(token)}`;
}

// ✅ 駁回原因小表單（GET 表單送回本身，導向 action=rejectSubmit）
function rejectFormOut_(reqId, token) {
  const html = `
    <div style="font-family:system-ui; padding:24px; max-width:480px; margin:0 auto;">
      <h3>駁回補打卡申請</h3>
      <p>單號：${escapeHtml_(reqId)}</p>
      <form method="GET" action="${escapeHtml_(REVIEW_PROXY_URL)}">
        <input type="hidden" name="action" value="rejectSubmit">
        <input type="hidden" name="reqId" value="${escapeHtml_(reqId)}">
        <input type="hidden" name="token" value="${escapeHtml_(token)}">
        <label for="rejectReason">拒絕原因：</label><br>
        <textarea id="rejectReason" name="rejectReason" rows="4"
          style="width:100%; box-sizing:border-box; margin-top:6px;" required></textarea>
        <br><br>
        <button type="submit" style="padding:8px 20px; font-size:14px;">確認駁回</button>
      </form>
    </div>
  `;
  return HtmlService.createHtmlOutput(html);
}

/* ===================== Spreadsheet Helpers ===================== */

function getSS_() {
  return SpreadsheetApp.openById(SPREADSHEET_ID);
}

function getSheet_(name) {
  const ss = getSS_();
  const sh = ss.getSheetByName(name);
  if (!sh) throw new Error('Sheet not found: ' + name);
  return sh;
}

/**
 * ✅ 僅保留一個版本：Exception_Requests 取得或建立 + 表頭治理
 */
function getOrCreateExceptionSheet_() {
  const ss = getSS_();
  let sh = ss.getSheetByName(SHEET_EXC);
  if (!sh) sh = ss.insertSheet(SHEET_EXC);

  // ✅ true = 重排整張表（含資料）使欄位統一，避免欄位錯位導致回寫錯欄
  ensureExceptionRequestHeaders_(sh, true);
  return sh;
}

function getOrCreateWorkHourSheet_() {
  const ss = getSS_();
  let sh = ss.getSheetByName(SHEET_WORKHOUR);
  if (!sh) {
    sh = ss.insertSheet(SHEET_WORKHOUR);
    sh.getRange(1, 1, 1, 5).setValues([[
      'empId', 'weekId', 'weeklyWorkHours', 'weeklyHourLimit', 'workHourStatus'
    ]]);
    sh.setFrozenRows(1);
    sh.getRange(1, 1, 1, 5).setFontWeight('bold').setBackground('#f3f3f3');
  }
  return sh;
}

function getSupervisorEmail_() {
  try {
    const sh = getSheet_(SHEET_SETTINGS);
    const lastRow = sh.getLastRow();
    const lastCol = sh.getLastColumn();
    if (lastRow < 2 || lastCol < 2) return '';

    const values = sh.getRange(1, 1, lastRow, lastCol).getValues();
    const headers = values[0].map(h => String(h || '').trim());
    const iKey = headers.indexOf('key');
    const iVal = headers.indexOf('value');
    if (iKey < 0 || iVal < 0) return '';

    for (let r = 1; r < values.length; r++) {
      const k = String(values[r][iKey] || '').trim();
      const v = String(values[r][iVal] || '').trim();
      if (k === 'supervisorEmail') return v;
    }
    return '';
  } catch (e) {
    return '';
  }
}

// ✅ 讀取 Settings!supervisorEmpIds，做為核准/駁回時寫入 reviewedBy 的主管身分
function getSupervisorEmpId_() {
  try {
    const sh = getSheet_(SHEET_SETTINGS);
    const lastRow = sh.getLastRow();
    const lastCol = sh.getLastColumn();
    if (lastRow < 2 || lastCol < 2) return '';

    const values = sh.getRange(1, 1, lastRow, lastCol).getValues();
    const headers = values[0].map(h => String(h || '').trim());
    const iKey = headers.indexOf('key');
    const iVal = headers.indexOf('value');
    if (iKey < 0 || iVal < 0) return '';

    for (let r = 1; r < values.length; r++) {
      const k = String(values[r][iKey] || '').trim();
      const v = String(values[r][iVal] || '').trim();
      if (k === 'supervisorEmpIds') return v;
    }
    return '';
  } catch (e) {
    return '';
  }
}

/**
 * ✅ 確保 Exception_Requests 表頭存在且正確
 * - 若缺欄位：自動補到最右側
 * - 若 forceReorder=true：依標準順序重排整張表（包含資料）
 */
function ensureExceptionRequestHeaders_(sh, forceReorder) {
  const standardHeaders = [
    'timestamp', 'reqId', 'status', 'empId', 'empName', 'date',
    'punchType', 'requestedPunchAt',
    'firstPunch', 'lastPunch', 'reason', 'source', 'userAgent', 'token',
    'rejectReason', 'empSeenAt', 'reviewedBy', 'reviewedAt'
  ];

  const lastRow = sh.getLastRow();
  const lastCol = sh.getLastColumn();

  // 空表：直接建表頭
  if (lastRow < 1 || lastCol < 1) {
    sh.getRange(1, 1, 1, standardHeaders.length).setValues([standardHeaders]);
    sh.setFrozenRows(1);
    sh.getRange(1, 1, 1, standardHeaders.length).setFontWeight('bold').setBackground('#f3f3f3');
    return { headers: standardHeaders, map: indexMap_(standardHeaders), standardHeaders };
  }

  // 讀現有表頭（去除尾端空白）
  let headers = sh.getRange(1, 1, 1, lastCol).getValues()[0].map(h => String(h || '').trim());
  while (headers.length > 0 && !headers[headers.length - 1]) headers.pop();

  const headerSet = {};
  headers.forEach(h => { if (h) headerSet[h] = true; });

  // 補缺欄位到最右
  const missing = standardHeaders.filter(h => !headerSet[h]);
  if (missing.length > 0) {
    sh.getRange(1, headers.length + 1, 1, missing.length).setValues([missing]);
    headers = headers.concat(missing);
  }

  sh.setFrozenRows(1);
  sh.getRange(1, 1, 1, headers.length).setFontWeight('bold').setBackground('#f3f3f3');

  if (!forceReorder) {
    return { headers, map: indexMap_(headers), standardHeaders };
  }

  // ✅ 強制重排（含資料）
  const dataLastRow = sh.getLastRow();
  const dataLastCol = Math.max(sh.getLastColumn(), headers.length);
  const values = sh.getRange(1, 1, dataLastRow, dataLastCol).getValues();

  const currentHeaders = values[0].map(h => String(h || '').trim());
  const curMap = indexMap_(currentHeaders);

  const newValues = [];
  newValues.push(standardHeaders);

  for (let r = 1; r < values.length; r++) {
    const oldRow = values[r];
    const newRow = new Array(standardHeaders.length).fill('');
    for (let c = 0; c < standardHeaders.length; c++) {
      const h = standardHeaders[c];
      const idx = curMap[h];
      newRow[c] = (idx === undefined) ? '' : oldRow[idx];
    }
    newValues.push(newRow);
  }

  sh.clearContents();
  sh.getRange(1, 1, newValues.length, standardHeaders.length).setValues(newValues);
  sh.setFrozenRows(1);
  sh.getRange(1, 1, 1, standardHeaders.length).setFontWeight('bold').setBackground('#f3f3f3');

  return { headers: standardHeaders, map: indexMap_(standardHeaders), standardHeaders };
}

function indexMap_(headers) {
  const map = {};
  for (let i = 0; i < headers.length; i++) {
    const h = String(headers[i] || '').trim();
    if (h) map[h] = i;
  }
  return map;
}

/* ===================== Data Loaders ===================== */

function getEmployees_() {
  const rows = readSheetAsObjects_(SHEET_EMP);
  return rows
    .filter(r => r.empId && r.empName)
    .map(r => ({
      empId: String(r.empId).trim(),
      empName: String(r.empName).trim(),
      pin: String(r.pin || '').trim(),
      weeklyHourLimit: (r.weeklyHourLimit === undefined || r.weeklyHourLimit === '') ? '' : Number(r.weeklyHourLimit),
    }));
}

function getEmployeeById_(empId) {
  const rows = readSheetAsObjects_(SHEET_EMP);
  const id = String(empId || '').trim();
  if (!id) return null;

  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (String(r.empId || '').trim() === id) {
      return {
        empId: String(r.empId || '').trim(),
        empName: String(r.empName || '').trim(),
        pin: String(r.pin || '').trim(),
        weeklyHourLimit: (r.weeklyHourLimit === undefined || r.weeklyHourLimit === '') ? null : Number(r.weeklyHourLimit),
      };
    }
  }
  return null;
}

function getEmployeeByName_(empName) {
  const rows = readSheetAsObjects_(SHEET_EMP);
  const name = String(empName || '').trim();
  if (!name) return null;

  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (String(r.empName || '').trim() === name) {
      return {
        empId: String(r.empId || '').trim(),
        empName: String(r.empName || '').trim(),
        pin: String(r.pin || '').trim(),
        weeklyHourLimit: (r.weeklyHourLimit === undefined || r.weeklyHourLimit === '') ? null : Number(r.weeklyHourLimit),
      };
    }
  }
  return null;
}

function getShifts_() {
  const rows = readSheetAsObjects_(SHEET_SHIFT);
  return rows
    .filter(r => r.shiftId && (r.startTime || r.start) && (r.endTime || r.end))
    .map(r => ({
      shiftId: String(r.shiftId).trim(),
      start: formatTimeValue_(r.startTime || r.start),
      end: formatTimeValue_(r.endTime || r.end),
      graceInMin: toInt_(r.graceInMin, 0),
      graceOutMin: toInt_(r.graceOutMin, 0),
    }));
}

// ✅ Shift_Template 的時間欄位若被 Sheets 格式化成「時間」類型，
// 讀出來會是以 1899-12-30 為基底的 Date 物件；這裡統一轉成 HH:mm 純文字。
function formatTimeValue_(v) {
  if (v instanceof Date) {
    if (isNaN(v.getTime())) return '';
    return Utilities.formatDate(v, TZ, 'HH:mm');
  }
  const s = String(v || '').trim();
  const m = s.match(/^(\d{1,2}):(\d{2})/);
  if (m) return `${m[1].padStart(2, '0')}:${m[2]}`;
  return s;
}

function getRoster_() {
  const rows = readSheetAsObjects_(SHEET_ROSTER);
  return rows
    .filter(r => r.workDate && r.empId && r.shiftId)
    .map(r => ({
      date: normalizeDate_(r.workDate),
      empId: String(r.empId).trim(),
      shiftId: String(r.shiftId).trim(),
    }));
}

function getGeoFencePoints_() {
  try {
    const rows = readSheetAsObjects_(SHEET_GEOFENCE);
    return rows
      .filter(r => r.id && r.name && r.lat && r.lng)
      .map(r => ({
        id: String(r.id).trim(),
        name: String(r.name).trim(),
        lat: Number(r.lat),
        lng: Number(r.lng),
        radiusM: r.radiusM ? Number(r.radiusM) : 300,
      }));
  } catch (e) {
    return [];
  }
}

/* ===================== GeoFence Check ===================== */

function checkGeoFence_(lat, lng) {
  const points = getGeoFencePoints_();
  if (!points || points.length === 0) return { allowed: true };

  let nearest = null;
  let nearestD = null;
  let allowed = false;

  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    const d = distanceMeters_(lat, lng, p.lat, p.lng);

    if (nearestD === null || d < nearestD) {
      nearestD = d;
      nearest = p;
    }
    if (d <= Number(p.radiusM || 300)) allowed = true;
  }

  return {
    allowed,
    nearestName: nearest ? nearest.name : '',
    nearestDistanceM: nearestD,
    nearestRadiusM: nearest ? Number(nearest.radiusM || 300) : 0,
  };
}

function distanceMeters_(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (x) => x * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);

  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/* ===================== dayPunch ===================== */

function getDayPunchFromLog_(empId, dateStr) {
  const ss = getSS_();
  const sh = ss.getSheetByName(SHEET_PUNCH);
  if (!sh) return { firstPunch: null, lastPunch: null };

  const lastRow = sh.getLastRow();
  const lastCol = sh.getLastColumn();
  if (lastRow < 2 || lastCol < 1) return { firstPunch: null, lastPunch: null };

  const values = sh.getRange(1, 1, lastRow, lastCol).getValues();
  const headers = values[0].map(h => String(h || '').trim());

  const idx = (name) => headers.indexOf(name);
  const iEmp = idx('empId');
  const iDate = idx('date');
  const iFirst = idx('firstPunch');
  const iLast = idx('lastPunch');

  if (iEmp < 0 || iDate < 0) throw new Error('Punch_Log missing columns: empId/date');
  if (iFirst < 0 || iLast < 0) throw new Error('Punch_Log missing columns: firstPunch/lastPunch');

  let bestFirst = null;
  let bestLast = null;

  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    if (String(row[iEmp] || '').trim() !== empId) continue;
    if (String(row[iDate] || '').trim() !== dateStr) continue;

    const f = smartParsePunchValue_(dateStr, row[iFirst]);
    const l = smartParsePunchValue_(dateStr, row[iLast]);

    if (f && (!bestFirst || f.getTime() < bestFirst.getTime())) bestFirst = f;
    if (l && (!bestLast || l.getTime() > bestLast.getTime())) bestLast = l;
  }

  return {
    firstPunch: bestFirst ? bestFirst.toISOString() : null,
    lastPunch: bestLast ? bestLast.toISOString() : null
  };
}

/* ===================== Write Punch ===================== */

function appendPunch_(p) {
  const ss = getSS_();
  let sheet = ss.getSheetByName(SHEET_PUNCH);

  const headers = [
    'timestamp', 'empId', 'empName', 'date', 'firstPunch', 'lastPunch',
    'source', 'userAgent',
    'lat', 'lng', 'accuracyM',
    'status', 'exceptionReason', 'approvedBy'
  ];

  if (!sheet) {
    sheet = ss.insertSheet(SHEET_PUNCH);
    sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, headers.length).setFontWeight('bold').setBackground('#f3f3f3');
  }

  const firstDt = smartParsePunchValue_(p.date, p.firstPunch);
  const lastDt = smartParsePunchValue_(p.date, p.lastPunch);

  const dateStr = normalizeDate_(p.date);

  sheet.appendRow([
    new Date(),
    p.empId || '',
    p.empName || '',
    dateStr,
    firstDt || '',
    lastDt || '',
    p.source || '',
    p.userAgent || '',
    p.lat === undefined ? '' : p.lat,
    p.lng === undefined ? '' : p.lng,
    p.accuracyM === undefined ? '' : p.accuracyM,
    p.status || '',
    p.exceptionReason || '',
    p.approvedBy || '',
  ]);

  const lastRow = sheet.getLastRow();
  sheet.getRange(lastRow, 4).setNumberFormat('@');
  sheet.getRange(lastRow, 5, 1, 2).setNumberFormat('yyyy-MM-dd HH:mm:ss');
}

/* ===================== WorkHour_Check ===================== */

function updateWorkHourCheck_(empId, dateYmd) {
  const ss = getSS_();
  const shPunch = ss.getSheetByName(SHEET_PUNCH);
  if (!shPunch) return;

  const targetDate = parsePunchDateTime_(dateYmd, '00:00:00');
  if (!targetDate) return;

  const week = getIsoWeekInfo_(targetDate);
  const weekId = week.weekId;

  const emp = getEmployeeById_(empId);
  const weeklyLimit = (emp && emp.weeklyHourLimit != null && !isNaN(emp.weeklyHourLimit)) ? Number(emp.weeklyHourLimit) : 40;

  const lastRow = shPunch.getLastRow();
  const lastCol = shPunch.getLastColumn();
  if (lastRow < 2) return;

  const values = shPunch.getRange(1, 1, lastRow, lastCol).getValues();
  const headers = values[0].map(h => String(h || '').trim());
  const idx = (name) => headers.indexOf(name);

  const iEmp = idx('empId');
  const iDate = idx('date');
  const iFirst = idx('firstPunch');
  const iLast = idx('lastPunch');
  const iStatus = idx('status');

  if (iEmp < 0 || iDate < 0 || iFirst < 0 || iLast < 0) return;

  let sumHours = 0;

  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    if (String(row[iEmp] || '').trim() !== String(empId).trim()) continue;

    const ymd = String(row[iDate] || '').trim();
    if (!ymd) continue;

    const st = (iStatus >= 0) ? String(row[iStatus] || '').trim() : '';
    if (st && st !== 'NORMAL' && st !== 'APPROVED_EXCEPTION') continue;

    const d0 = parsePunchDateTime_(ymd, '00:00:00');
    if (!d0) continue;

    if (d0 < week.start || d0 > week.end) continue;

    const f = smartParsePunchValue_(ymd, row[iFirst]);
    const l = smartParsePunchValue_(ymd, row[iLast]);
    if (!f || !l) continue;

    let diffMs = l.getTime() - f.getTime();
    if (diffMs < 0) diffMs += 24 * 60 * 60 * 1000;

    sumHours += diffMs / (1000 * 60 * 60);
  }

  const weeklyWorkHours = Math.round(sumHours * 100) / 100;
  const workHourStatus = weeklyWorkHours > weeklyLimit ? '超時' : '正常';

  const shWH = getOrCreateWorkHourSheet_();
  const whLastRow = shWH.getLastRow();

  if (whLastRow < 2) {
    shWH.appendRow([String(empId).trim(), weekId, weeklyWorkHours, weeklyLimit, workHourStatus]);
    return;
  }

  const data = shWH.getRange(2, 1, whLastRow - 1, 5).getValues();
  for (let i = 0; i < data.length; i++) {
    const rEmp = String(data[i][0] || '').trim();
    const rWeek = String(data[i][1] || '').trim();
    if (rEmp === String(empId).trim() && rWeek === weekId) {
      shWH.getRange(i + 2, 3).setValue(weeklyWorkHours);
      shWH.getRange(i + 2, 4).setValue(weeklyLimit);
      shWH.getRange(i + 2, 5).setValue(workHourStatus);
      return;
    }
  }

  shWH.appendRow([String(empId).trim(), weekId, weeklyWorkHours, weeklyLimit, workHourStatus]);
}

function getIsoWeekInfo_(dateObj) {
  const d = new Date(dateObj.getTime());
  const y = Number(Utilities.formatDate(d, TZ, 'yyyy'));
  const m = Number(Utilities.formatDate(d, TZ, 'MM'));
  const dd = Number(Utilities.formatDate(d, TZ, 'dd'));
  const local = new Date(y, m - 1, dd, 12, 0, 0);

  const jsDay = local.getDay();
  const isoDay = jsDay === 0 ? 7 : jsDay;

  const thursday = new Date(local.getTime());
  thursday.setDate(local.getDate() + (4 - isoDay));

  const weekYear = thursday.getFullYear();

  const jan4 = new Date(weekYear, 0, 4, 12, 0, 0);
  const jan4JsDay = jan4.getDay();
  const jan4IsoDay = jan4JsDay === 0 ? 7 : jan4JsDay;
  const firstWeekThursday = new Date(jan4.getTime());
  firstWeekThursday.setDate(jan4.getDate() + (4 - jan4IsoDay));

  const diffDays = Math.round((thursday - firstWeekThursday) / (24 * 60 * 60 * 1000));
  const weekNo = 1 + Math.floor(diffDays / 7);

  const ww = String(weekNo).padStart(2, '0');
  const weekId = `${weekYear}W${ww}`;

  const start = new Date(local.getFullYear(), local.getMonth(), local.getDate(), 0, 0, 0);
  start.setDate(start.getDate() - (isoDay - 1));

  const end = new Date(start.getFullYear(), start.getMonth(), start.getDate(), 23, 59, 59);
  end.setDate(end.getDate() + 6);

  return { weekYear, weekNo, weekId, start, end };
}

/* ===================== Date/Time Parsing (Enhanced) ===================== */

function parsePunchDateTime_(dateYmd, timeOrDateTime) {
  if (!timeOrDateTime) return null;
  if (timeOrDateTime instanceof Date) return timeOrDateTime;

  const dateStr = String(dateYmd || '').trim();
  const s = String(timeOrDateTime).trim();
  if (!s) return null;

  // 1) HH:mm / HH:mm:ss
  if (/^\d{1,2}:\d{2}(:\d{2})?$/.test(s) && /^\d{4}-\d{2}-\d{2}$/.test(dateStr)) {
    return buildLocalDate_(dateStr, s);
  }

  // 2) yyyy-MM-dd HH:mm[:ss]
  if (/^\d{4}-\d{2}-\d{2}\s+\d{1,2}:\d{2}(:\d{2})?$/.test(s)) {
    const parts = s.split(/\s+/);
    return buildLocalDate_(parts[0], parts[1]);
  }

  // 3) Google Sheets 中文格式 yyyy/M/d 上午/下午 h:mm:ss
  const cnMatch = s.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})\s+(上午|下午)\s+(\d{1,2}):(\d{2}):(\d{2})$/);
  if (cnMatch) {
    const y = cnMatch[1];
    const m = cnMatch[2].padStart(2, '0');
    const d = cnMatch[3].padStart(2, '0');
    const period = cnMatch[4];
    let h = parseInt(cnMatch[5], 10);
    const mm = cnMatch[6];
    const ss = cnMatch[7];

    if (period === '下午' && h < 12) h += 12;
    if (period === '上午' && h === 12) h = 0;

    const hh = String(h).padStart(2, '0');
    return buildLocalDate_(`${y}-${m}-${d}`, `${hh}:${mm}:${ss}`);
  }

  // 4) ISO/GMT
  const d = new Date(s);
  if (!isNaN(d.getTime())) return d;

  // 5) yyyy-MM-dd
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    return buildLocalDate_(s, '00:00:00');
  }

  return null;
}

function smartParsePunchValue_(dateYmd, value) {
  if (!value) return null;

  if (value instanceof Date) {
    if (!isNaN(value.getTime())) return value;
    return null;
  }

  return parsePunchDateTime_(dateYmd, value);
}

function buildLocalDate_(ymd, hms) {
  const dParts = String(ymd).trim().split('-');
  if (dParts.length !== 3) return null;
  const y = Number(dParts[0]);
  const m = Number(dParts[1]);
  const d = Number(dParts[2]);

  const t = String(hms).trim().split(':');
  const hh = Number(t[0] || 0);
  const mm = Number(t[1] || 0);
  const ss = Number(t[2] || 0);

  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) return null;
  if (!Number.isFinite(hh) || !Number.isFinite(mm) || !Number.isFinite(ss)) return null;

  return new Date(y, m - 1, d, hh, mm, ss);
}

/* ===================== Utils ===================== */

function readSheetAsObjects_(sheetName) {
  const sheet = getSheet_(sheetName);

  const lastRow = sheet.getLastRow();
  const lastCol = sheet.getLastColumn();
  if (lastRow < 2 || lastCol < 1) return [];

  const values = sheet.getRange(1, 1, lastRow, lastCol).getValues();
  const headers = values[0].map(h => String(h || '').trim());

  const out = [];
  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    const obj = {};
    let hasAny = false;

    for (let c = 0; c < headers.length; c++) {
      const key = headers[c];
      if (!key) continue;
      const v = row[c];
      if (v !== '' && v !== null && v !== undefined) hasAny = true;
      obj[key] = v;
    }
    if (hasAny) out.push(obj);
  }
  return out;
}

function parseBody_(e) {
  if (!e || !e.postData) return {};
  if (!e.postData.contents) return {};

  const raw = String(e.postData.contents);

  if (raw.trim().startsWith('{')) {
    try { return JSON.parse(raw); } catch (err) {
      Logger.log('JSON parse error: ' + err);
      return {};
    }
  }
  return parseQueryString_(raw);
}

function parseQueryString_(s) {
  const obj = {};
  String(s).split('&').forEach(pair => {
    const parts = pair.split('=');
    const k = parts[0];
    const v = parts[1];
    if (!k) return;
    obj[decodeURIComponent(k)] = decodeURIComponent(v || '');
  });
  return obj;
}

/**
 * 將前端傳入的補卡類型統一為 CLOCK_IN / CLOCK_OUT。
 * 同時接受中英文常見值，降低前後端版本差異造成的失敗。
 */
function normalizePunchType_(v) {
  const s = String(v || '').trim().toUpperCase();
  if (!s) return '';
  if (['CLOCK_IN', 'IN', 'FIRST', 'START', '上班', '補上班卡'].includes(s)) {
    return 'CLOCK_IN';
  }
  if (['CLOCK_OUT', 'OUT', 'LAST', 'END', '下班', '補下班卡'].includes(s)) {
    return 'CLOCK_OUT';
  }
  return '';
}

function punchTypeLabel_(punchType) {
  if (punchType === 'CLOCK_IN') return '補上班卡';
  if (punchType === 'CLOCK_OUT') return '補下班卡';
  return '舊版例外補卡';
}

function normalizeDate_(v) {
  if (!v) return '';

  if (v instanceof Date) {
    if (isNaN(v.getTime())) return '';
    return Utilities.formatDate(v, TZ, 'yyyy-MM-dd');
  }

  const s = String(v).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;

  const d = new Date(s);
  if (!isNaN(d.getTime())) {
    return Utilities.formatDate(d, TZ, 'yyyy-MM-dd');
  }

  return s;
}

function toInt_(v, def) {
  if (v === null || v === undefined || v === '') return def;
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : def;
}

function jsonOut(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function htmlOut_(text) {
  return HtmlService.createHtmlOutput(`<div style="font-family:system-ui; padding:16px;">${escapeHtml_(text)}</div>`);
}

function escapeHtml_(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function getOrInitSecret_() {
  const props = PropertiesService.getScriptProperties();
  let secret = props.getProperty(PROP_SECRET_KEY);
  if (!secret) {
    secret = Utilities.getUuid() + Utilities.getUuid();
    props.setProperty(PROP_SECRET_KEY, secret);
  }
  return secret;
}

/* ===================== 清洗現有資料工具（保留你的工具） ===================== */

function fixPunchLogEmpIdEmpName() {
  const ss = getSS_();
  const sh = ss.getSheetByName(SHEET_PUNCH);
  if (!sh) { Logger.log('❌ Punch_Log sheet not found'); return; }

  const employees = getEmployees_();
  const nameToIdMap = {};
  const idToNameMap = {};
  employees.forEach(emp => {
    const cleanName = String(emp.empName || '').trim();
    const cleanId = String(emp.empId || '').trim();
    if (cleanName && cleanId) {
      nameToIdMap[cleanName] = cleanId;
      idToNameMap[cleanId] = cleanName;
    }
  });

  const lastRow = sh.getLastRow();
  const lastCol = sh.getLastColumn();
  if (lastRow < 2) { Logger.log('✅ No data to fix'); return; }

  const values = sh.getRange(1, 1, lastRow, lastCol).getValues();
  const headers = values[0].map(h => String(h || '').trim());
  const iEmpId = headers.indexOf('empId');
  const iEmpName = headers.indexOf('empName');
  if (iEmpId < 0 || iEmpName < 0) { Logger.log('❌ Punch_Log missing columns: empId/empName'); return; }

  let fixed = 0;
  let notFound = 0;
  const problematicRows = [];

  for (let r = 1; r < values.length; r++) {
    let empIdValue = values[r][iEmpId];
    let empNameValue = values[r][iEmpName];

    empIdValue = empIdValue == null ? '' : String(empIdValue).trim();
    empNameValue = empNameValue == null ? '' : String(empNameValue).trim();

    if (!empIdValue && !empNameValue) continue;

    const hasChinese = /[一-龥]/.test(empIdValue);
    const idTooLong = empIdValue.length > 10;
    const isProblem = hasChinese || idTooLong || (!empIdValue && empNameValue) || (empIdValue && !empNameValue);

    if (!isProblem) continue;

    if (hasChinese) {
      const supposedName = empIdValue;
      if (nameToIdMap[supposedName]) {
        const correctId = nameToIdMap[supposedName];
        sh.getRange(r + 1, iEmpId + 1).setValue(correctId);
        sh.getRange(r + 1, iEmpName + 1).setValue(supposedName);
        fixed++;
      } else {
        problematicRows.push(r + 1);
        notFound++;
      }
      continue;
    }

    if (!empIdValue && empNameValue) {
      if (nameToIdMap[empNameValue]) {
        sh.getRange(r + 1, iEmpId + 1).setValue(nameToIdMap[empNameValue]);
        fixed++;
      } else if (idToNameMap[empNameValue]) {
        sh.getRange(r + 1, iEmpId + 1).setValue(empNameValue);
        sh.getRange(r + 1, iEmpName + 1).setValue(idToNameMap[empNameValue]);
        fixed++;
      } else {
        problematicRows.push(r + 1);
        notFound++;
      }
      continue;
    }

    if (empIdValue && !empNameValue) {
      if (idToNameMap[empIdValue]) {
        sh.getRange(r + 1, iEmpName + 1).setValue(idToNameMap[empIdValue]);
        fixed++;
      } else {
        problematicRows.push(r + 1);
        notFound++;
      }
      continue;
    }

    if (empIdValue && empNameValue && idToNameMap[empIdValue]) {
      const expectedName = idToNameMap[empIdValue];
      if (expectedName !== empNameValue) {
        sh.getRange(r + 1, iEmpName + 1).setValue(expectedName);
        fixed++;
      }
    }
  }

  Logger.log(`✅ 修復完成 fixed=${fixed}, notFound=${notFound}, rows=${problematicRows.join(',')}`);
}

function normalizeExceptionRequestDates() {
  const ss = getSS_();
  const sh = ss.getSheetByName(SHEET_EXC);
  if (!sh) { Logger.log('❌ Exception_Requests sheet not found'); return; }

  const lastRow = sh.getLastRow();
  if (lastRow < 2) { Logger.log('✅ No data to normalize'); return; }

  const values = sh.getDataRange().getValues();
  const headers = values[0].map(h => String(h || '').trim());
  const iDate = headers.indexOf('date');
  if (iDate < 0) { Logger.log('❌ Exception_Requests missing column: date'); return; }

  let changed = 0;
  for (let r = 1; r < values.length; r++) {
    const rawDate = values[r][iDate];
    const normalizedDate = normalizeDate_(rawDate);
    if (normalizedDate && normalizedDate !== String(rawDate)) {
      sh.getRange(r + 1, iDate + 1).setValue(normalizedDate);
      changed++;
    }
  }
  Logger.log(`✅ Exception_Requests 清洗完成 changed=${changed}`);
}

function normalizePunchLogDateColumns() {
  const ss = getSS_();
  const sh = ss.getSheetByName(SHEET_PUNCH);
  if (!sh) { Logger.log('❌ Punch_Log sheet not found'); return; }

  const lastRow = sh.getLastRow();
  const lastCol = sh.getLastColumn();
  if (lastRow < 2) { Logger.log('✅ No data to normalize'); return; }

  const values = sh.getRange(1, 1, lastRow, lastCol).getValues();
  const headers = values[0].map(h => String(h || '').trim());
  const iDate = headers.indexOf('date');
  const iFirst = headers.indexOf('firstPunch');
  const iLast = headers.indexOf('lastPunch');
  if (iDate < 0 || iFirst < 0 || iLast < 0) { Logger.log('❌ Punch_Log missing date/firstPunch/lastPunch'); return; }

  let changedDate = 0;
  let changedTime = 0;
  let errors = 0;

  for (let r = 1; r < values.length; r++) {
    try {
      const rawDate = values[r][iDate];
      const normalizedDate = normalizeDate_(rawDate);
      if (normalizedDate && normalizedDate !== String(rawDate)) {
        sh.getRange(r + 1, iDate + 1).setValue(normalizedDate).setNumberFormat('@');
        changedDate++;
      }
      const dateStr = normalizedDate || String(rawDate || '').trim();

      const f1 = smartParsePunchValue_(dateStr, values[r][iFirst]);
      if (f1 instanceof Date && !isNaN(f1.getTime())) {
        sh.getRange(r + 1, iFirst + 1).setValue(f1);
        changedTime++;
      } else if (values[r][iFirst]) {
        errors++;
      }

      const l1 = smartParsePunchValue_(dateStr, values[r][iLast]);
      if (l1 instanceof Date && !isNaN(l1.getTime())) {
        sh.getRange(r + 1, iLast + 1).setValue(l1);
        changedTime++;
      } else if (values[r][iLast]) {
        errors++;
      }
    } catch (e) {
      errors++;
    }
  }

  sh.getRange(2, iDate + 1, lastRow - 1, 1).setNumberFormat('@');
  sh.getRange(2, iFirst + 1, lastRow - 1, 1).setNumberFormat('yyyy-MM-dd HH:mm:ss');
  sh.getRange(2, iLast + 1, lastRow - 1, 1).setNumberFormat('yyyy-MM-dd HH:mm:ss');

  Logger.log(`✅ Punch_Log 清洗完成 date=${changedDate}, timeCells=${changedTime}, errors=${errors}`);
}

function normalizeAllDates() {
  Logger.log('=== normalizeAllDates start ===');
  normalizePunchLogDateColumns();
  normalizeExceptionRequestDates();
  Logger.log('=== normalizeAllDates done ===');
}

function fullRepair() {
  Logger.log('=== fullRepair start ===');
  fixPunchLogEmpIdEmpName();
  normalizeAllDates();
  Logger.log('=== fullRepair done ===');
}
