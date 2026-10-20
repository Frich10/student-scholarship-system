/**
 * Scholarship Monitoring: browser client.
 *
 * All reads use Supabase queries limited by row-level security.
 * All writes call database functions (see supabase/schema.sql), which enforce
 * roles and business rules on the server.
 */
'use strict';

const client = supabase.createClient(CFG.url, CFG.key);

/* --------------------------------------------------------------------------
 * State
 * ------------------------------------------------------------------------ */
const state = {
  me: null,            // signed-in profile
  programs: {},        // program id -> program row
  assignments: {},     // scholar id -> assignment row
  submissions: [],     // visible submissions (RLS-filtered)
  editingId: null,     // submission being corrected, if any
};

/* --------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------ */
const $ = (selector) => document.querySelector(selector);

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };

/** Escapes text for safe insertion into HTML. */
function esc(value) {
  return String(value ?? '').replace(/[&<>"]/g, (c) => HTML_ESCAPES[c]);
}

/** Formats a timestamp in Asia/Manila time. */
function formatTime(value) {
  return new Date(value).toLocaleString('en-PH', { timeZone: 'Asia/Manila' });
}

/** Shows a status banner that hides itself after a few seconds. */
function showMessage(text, isError = false) {
  const banner = $('#msg');
  banner.textContent = text;
  banner.className = isError ? 'bad' : 'ok';
  banner.hidden = !text;
  clearTimeout(showMessage.timer);
  showMessage.timer = setTimeout(() => { banner.hidden = true; }, 7000);
}

/** Calls a database function; shows the server's message on failure. */
async function callRpc(name, args) {
  const { error } = await client.rpc(name, args);
  if (error) {
    showMessage(error.message, true);
    return false;
  }
  return true;
}

/* --------------------------------------------------------------------------
 * HTML fragments
 * ------------------------------------------------------------------------ */
const badge = (label) =>
  `<span class="badge ${label.replace(/\W/g, '')}">${label}</span>`;

const note = (text) => (text ? `<small>${esc(text)}</small>` : '');

const submissionCell = (s) =>
  badge(s.verification_status) + note(s.verification_reason);

const complianceCell = (s) =>
  badge(s.compliance_result) +
  (s.deficiency_reasons || []).map((r) => `<small>&bull; ${esc(r)}</small>`).join('');

const renewalCell = (s) => badge(s.renewal_decision) + note(s.decision_note);

const countsCell = (s) => `${s.units} / ${s.failed} / ${s.inc} / ${s.dropped}`;

const actionButton = (action, label, id, extraClass = '') =>
  `<button type="button" class="small ${extraClass}" data-action="${action}" data-id="${id}">${label}</button>`;

/* --------------------------------------------------------------------------
 * Authentication
 * ------------------------------------------------------------------------ */
$('#login').addEventListener('submit', async (event) => {
  event.preventDefault();
  const { error } = await client.auth.signInWithPassword({
    email: $('#em').value,
    password: $('#pw').value,
  });
  if (error) {
    showMessage(error.message, true);
  } else {
    boot();
  }
});

$('#signup').addEventListener('click', async () => {
  const { error } = await client.auth.signUp({
    email: $('#em').value,
    password: $('#pw').value,
  });
  showMessage(
    error ? error.message : 'Account created. Confirm your email if asked, then log in.',
    Boolean(error)
  );
});

$('#out').addEventListener('click', async () => {
  await client.auth.signOut();
  location.reload();
});

/* --------------------------------------------------------------------------
 * Startup and data loading
 * ------------------------------------------------------------------------ */
async function boot() {
  const { data } = await client.rpc('whoami');
  state.me = data && data[0];
  $('#out').hidden = false;

  if (!state.me) {
    showMessage('No scholarship profile for this email. Ask staff to register you.', true);
    return;
  }

  $('#auth').hidden = true;
  $('#who').textContent = `${state.me.full_name} (${state.me.role})`;

  const [programs, assignments] = await Promise.all([
    client.from('programs').select('*').order('id'),
    client.from('assignments').select('*'),
  ]);
  state.programs = Object.fromEntries(programs.data.map((p) => [p.id, p]));
  state.assignments = Object.fromEntries(assignments.data.map((a) => [a.scholar_id, a]));

  const isStaff = state.me.role === 'staff';
  $('#staff').hidden = !isStaff;
  $('#scholar').hidden = isStaff;

  if (isStaff) {
    const options = programs.data
      .map((p) => `<option value="${p.id}">${esc(p.name)}</option>`)
      .join('');
    $('#rp').innerHTML = options;
    $('#fp').innerHTML = `<option value="">All programs</option>${options}`;
  }

  await loadData();
}

async function loadData() {
  const { data, error } = await client
    .from('submissions')
    .select('*, profiles(full_name, student_id)')
    .order('submitted_at');
  if (error) {
    showMessage(error.message, true);
    return;
  }
  state.submissions = data;

  if (state.me.role === 'staff') {
    const { data: assignments } = await client.from('assignments').select('*');
    state.assignments = Object.fromEntries(assignments.map((a) => [a.scholar_id, a]));
    renderStaff();
  } else {
    renderScholar();
  }
}

/* --------------------------------------------------------------------------
 * Scholar view
 * ------------------------------------------------------------------------ */
function renderScholar() {
  const assignment = state.assignments[state.me.id];
  $('#prog').textContent = assignment
    ? `${state.programs[assignment.program_id].name}: award ${assignment.award_status}`
    : 'You are not assigned to a program yet.';

  const rows = state.submissions.map((s) => `
    <tr>
      <td>${s.academic_year} S${s.semester}</td>
      <td>${s.gwa}</td>
      <td>${countsCell(s)}</td>
      <td>${submissionCell(s)}</td>
      <td>${complianceCell(s)}</td>
      <td>${renewalCell(s)}</td>
      <td>
        ${s.verification_status === 'Returned' ? actionButton('edit', 'Correct', s.id) : ''}
        ${actionButton('history', 'History', s.id, 'ghost')}
      </td>
    </tr>`);

  $('#mine').innerHTML =
    rows.join('') || '<tr><td colspan="7">No submissions yet. Use the form above.</td></tr>';
}

$('#sf').addEventListener('submit', async (event) => {
  event.preventDefault();
  const f = event.target.elements;
  const num = (name) => (f[name].value === '' ? null : Number(f[name].value));

  const values = {
    p_gwa: num('gwa'),
    p_units: num('units'),
    p_failed: num('failed'),
    p_inc: num('inc'),
    p_drop: num('drop'),
    p_ev: f.ev.value,
  };

  const ok = state.editingId
    ? await callRpc('resubmit_grades', { p_id: state.editingId, ...values })
    : await callRpc('submit_grades', { p_year: f.year.value, p_sem: Number(f.sem.value), ...values });

  if (ok) {
    showMessage(state.editingId
      ? 'Resubmitted. Status is Pending verification.'
      : 'Submitted.');
    stopCorrection();
    loadData();
  }
});

function startCorrection(id) {
  const s = state.submissions.find((x) => x.id === id);
  const f = $('#sf').elements;

  state.editingId = id;
  f.year.value = s.academic_year;
  f.sem.value = s.semester;
  f.gwa.value = s.gwa;
  f.units.value = s.units;
  f.failed.value = s.failed;
  f.inc.value = s.inc;
  f.drop.value = s.dropped;
  f.ev.value = s.evidence_ref;
  f.year.disabled = true;
  f.sem.disabled = true;

  $('#cancel').hidden = false;
  $('#sft').textContent = 'Correct and resubmit';
  window.scrollTo(0, 0);
}

function stopCorrection() {
  const form = $('#sf');
  state.editingId = null;
  form.reset();
  form.elements.year.disabled = false;
  form.elements.sem.disabled = false;
  $('#cancel').hidden = true;
  $('#sft').textContent = 'Submit semester grades';
}

$('#cancel').addEventListener('click', stopCorrection);

/* --------------------------------------------------------------------------
 * Staff view
 * ------------------------------------------------------------------------ */
const STAFF_ACTIONS = [
  ['verify', 'Verify'],
  ['return', 'Return'],
  ['evaluate', 'Evaluate'],
  ['approve', 'Approve'],
  ['hold', 'Hold'],
  ['history', 'History'],
];

function renderStaff() {
  const termSelect = $('#sem');
  const terms = [...new Set(state.submissions.map((s) => `${s.academic_year}|${s.semester}`))];
  if (!terms.length) terms.push('2026-2027|1');

  const current = termSelect.value || terms[0];
  termSelect.innerHTML = terms
    .map((t) => `<option value="${t}" ${t === current ? 'selected' : ''}>AY ${t.replace('|', ' / Sem ')}</option>`)
    .join('');

  const inTerm = state.submissions.filter(
    (s) => `${s.academic_year}|${s.semester}` === termSelect.value
  );
  renderDashboard(inTerm);
  renderSubmissionTable(inTerm);
}

function renderDashboard(inTerm) {
  const countBy = (field, value) => inTerm.filter((s) => s[field] === value).length;
  const cards = [
    ['Assigned scholars', Object.keys(state.assignments).length],
    ['Pending verification', countBy('verification_status', 'Pending')],
    ['Compliant', countBy('compliance_result', 'Compliant')],
    ['With deficiency', countBy('compliance_result', 'With Deficiency')],
  ];
  $('#stats').innerHTML = cards
    .map(([label, value]) => `<div><b>${value}</b>${label}</div>`)
    .join('');
}

function renderSubmissionTable(inTerm) {
  const query = $('#q').value.toLowerCase();
  const program = $('#fp').value;
  const compliance = $('#fc').value;

  const matches = inTerm.filter((s) => {
    const text = `${s.profiles.full_name} ${s.profiles.student_id}`.toLowerCase();
    const assignment = state.assignments[s.scholar_id];
    return (
      (!query || text.includes(query)) &&
      (!program || String(assignment?.program_id) === program) &&
      (!compliance || s.compliance_result === compliance)
    );
  });

  const rows = matches.map((s) => {
    const assignment = state.assignments[s.scholar_id];
    const buttons = STAFF_ACTIONS
      .map(([action, label]) => actionButton(action, label, s.id, action === 'history' ? 'ghost' : ''))
      .join('');
    return `
      <tr>
        <td>${esc(s.profiles.full_name)}<small>${esc(s.profiles.student_id)}</small></td>
        <td>${esc(state.programs[assignment?.program_id]?.name)}</td>
        <td>${s.gwa}</td>
        <td>${countsCell(s)}<small>${esc(s.evidence_ref)}</small></td>
        <td>${formatTime(s.submitted_at)}</td>
        <td>${submissionCell(s)}</td>
        <td>${complianceCell(s)}</td>
        <td>${renewalCell(s)}</td>
        <td>${buttons}</td>
      </tr>`;
  });

  $('#rows').innerHTML = rows.join('') || '<tr><td colspan="9">No matching submissions.</td></tr>';
}

['#sem', '#fp', '#fc'].forEach((id) => $(id).addEventListener('change', renderStaff));
$('#q').addEventListener('input', renderStaff);

$('#rf').addEventListener('submit', async (event) => {
  event.preventDefault();
  const f = event.target.elements;
  const ok = await callRpc('register_scholar', {
    p_email: f.email.value,
    p_name: f.name.value,
    p_sid: f.sid.value,
    p_program: Number(f.prog.value),
  });
  if (ok) {
    showMessage('Scholar registered and assigned.');
    event.target.reset();
    loadData();
  }
});

/* --------------------------------------------------------------------------
 * Row actions (event delegation)
 * ------------------------------------------------------------------------ */
async function showHistory(id) {
  const { data, error } = await client
    .from('history')
    .select('*')
    .eq('submission_id', id)
    .order('created_at');
  if (error) {
    showMessage(error.message, true);
    return;
  }

  const entries = data
    .map((h) => `
      <p>
        <b>${esc(h.action)}</b> by ${esc(h.actor_name)}, ${formatTime(h.created_at)}
        <small>${esc(h.detail)}</small>
      </p>`)
    .join('');

  $('#dlg').innerHTML = `
    <h3>History</h3>
    ${entries || '<p>No entries.</p>'}
    <button type="button" onclick="this.closest('dialog').close()">Close</button>`;
  $('#dlg').showModal();
}

/** Maps a staff action to the database call it triggers. Returns true on success. */
async function runStaffAction(action, id) {
  switch (action) {
    case 'verify':
      return callRpc('verify_submission', { p_id: id, p_status: 'Verified', p_reason: null });
    case 'return': {
      const reason = prompt('Reason for returning this evidence?');
      if (reason === null) return false;
      return callRpc('verify_submission', { p_id: id, p_status: 'Returned', p_reason: reason });
    }
    case 'evaluate':
      return callRpc('evaluate_submission', { p_id: id });
    case 'approve': {
      const text = prompt('Decision note (optional)');
      if (text === null) return false;
      return callRpc('decide_renewal', { p_id: id, p_dec: 'Approved', p_note: text });
    }
    case 'hold': {
      const text = prompt('Reason for holding renewal?');
      if (text === null) return false;
      return callRpc('decide_renewal', { p_id: id, p_dec: 'Held', p_note: text });
    }
    default:
      return false;
  }
}

document.addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;

  const { action, id } = button.dataset;
  if (action === 'history') return showHistory(id);
  if (action === 'edit') return startCorrection(id);

  if (await runStaffAction(action, id)) {
    showMessage('Saved.');
    loadData();
  }
});

/* --------------------------------------------------------------------------
 * Resume an existing session
 * ------------------------------------------------------------------------ */
client.auth.getSession().then(({ data }) => {
  if (data.session) boot();
});
