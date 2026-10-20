CREATE TABLE programs (
  id           SERIAL PRIMARY KEY,
  name         TEXT          NOT NULL UNIQUE,
  max_gwa      NUMERIC(3, 2) NOT NULL CHECK (max_gwa BETWEEN 1 AND 5),
  min_units    INT           NOT NULL CHECK (min_units >= 0),
  max_failed   INT           NOT NULL CHECK (max_failed >= 0),
  max_inc      INT           NOT NULL CHECK (max_inc >= 0),
  max_dropped  INT           NOT NULL CHECK (max_dropped >= 0),
  deadline     TIMESTAMPTZ   NOT NULL
);

CREATE TABLE profiles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT NOT NULL UNIQUE,
  full_name   TEXT NOT NULL,
  student_id  TEXT UNIQUE,
  role        TEXT NOT NULL CHECK (role IN ('scholar', 'staff')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE assignments (
  id            SERIAL PRIMARY KEY,
  scholar_id    UUID NOT NULL UNIQUE REFERENCES profiles (id) ON DELETE CASCADE,
  program_id    INT  NOT NULL REFERENCES programs (id),
  award_status  TEXT NOT NULL DEFAULT 'Active'
                CHECK (award_status IN ('Active', 'Suspended', 'Ended'))
);

CREATE TABLE submissions (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  scholar_id          UUID          NOT NULL REFERENCES profiles (id) ON DELETE CASCADE,
  academic_year       TEXT          NOT NULL CHECK (academic_year ~ '^\d{4}-\d{4}$'),
  semester            INT           NOT NULL CHECK (semester IN (1, 2)),
  gwa                 NUMERIC(3, 2) NOT NULL CHECK (gwa BETWEEN 1 AND 5),
  units               INT           NOT NULL CHECK (units >= 0),
  failed              INT           NOT NULL CHECK (failed >= 0),
  inc                 INT           NOT NULL CHECK (inc >= 0),
  dropped             INT           NOT NULL CHECK (dropped >= 0),
  evidence_ref        TEXT          NOT NULL CHECK (length(trim(evidence_ref)) > 0),
  submitted_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  verification_status TEXT          NOT NULL DEFAULT 'Pending'
                      CHECK (verification_status IN ('Pending', 'Verified', 'Returned')),
  verification_reason TEXT,
  compliance_result   TEXT          NOT NULL DEFAULT 'Not Evaluated'
                      CHECK (compliance_result IN ('Not Evaluated', 'Compliant', 'With Deficiency')),
  deficiency_reasons  TEXT[]        NOT NULL DEFAULT '{}',
  renewal_decision    TEXT          NOT NULL DEFAULT 'None'
                      CHECK (renewal_decision IN ('None', 'Approved', 'Held')),
  decision_note       TEXT,
  UNIQUE (scholar_id, academic_year, semester)
);

CREATE TABLE history (
  id             BIGSERIAL PRIMARY KEY,
  submission_id  UUID NOT NULL REFERENCES submissions (id) ON DELETE CASCADE,
  action         TEXT NOT NULL,
  actor_id       UUID,
  actor_name     TEXT,
  detail         TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO programs (name, max_gwa, min_units, max_failed, max_inc, max_dropped, deadline)
VALUES
  ('Merit Scholar',     1.75, 18, 0, 0, 0, '2026-10-30 17:00+08'),
  ('Community Scholar', 2.25, 15, 0, 0, 1, '2026-10-30 17:00+08');

CREATE FUNCTION my_pid()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT id
  FROM profiles
  WHERE lower(email) = lower(auth.jwt() ->> 'email')
  LIMIT 1
$$;

CREATE FUNCTION is_staff()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM profiles
    WHERE lower(email) = lower(auth.jwt() ->> 'email')
      AND role = 'staff'
  )
$$;

CREATE FUNCTION whoami()
RETURNS SETOF profiles
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM profiles WHERE id = my_pid()
$$;

CREATE FUNCTION log_h(sid UUID, act TEXT, det TEXT)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  INSERT INTO history (submission_id, action, actor_id, actor_name, detail)
  VALUES (
    sid,
    act,
    my_pid(),
    (SELECT full_name FROM profiles WHERE id = my_pid()),
    det
  )
$$;
REVOKE EXECUTE ON FUNCTION log_h FROM PUBLIC, anon, authenticated;

CREATE FUNCTION chk_input(g NUMERIC, u INT, f INT, i INT, d INT, ev TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  IF g IS NULL OR g < 1 OR g > 5 THEN
    RAISE EXCEPTION 'Invalid GWA: must be between 1.00 and 5.00';
  END IF;
  IF u IS NULL OR u < 0 OR f IS NULL OR f < 0
     OR i IS NULL OR i < 0 OR d IS NULL OR d < 0 THEN
    RAISE EXCEPTION 'Units and counts must be non-negative integers';
  END IF;
  IF ev IS NULL OR length(trim(ev)) = 0 THEN
    RAISE EXCEPTION 'Grade-document reference is required';
  END IF;
END
$$;

ALTER TABLE programs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE history     ENABLE ROW LEVEL SECURITY;

CREATE POLICY programs_read ON programs
  FOR SELECT TO authenticated USING (true);

CREATE POLICY profiles_read ON profiles
  FOR SELECT TO authenticated
  USING (is_staff() OR id = my_pid());

CREATE POLICY assignments_read ON assignments
  FOR SELECT TO authenticated
  USING (is_staff() OR scholar_id = my_pid());

CREATE POLICY submissions_read ON submissions
  FOR SELECT TO authenticated
  USING (is_staff() OR scholar_id = my_pid());

CREATE POLICY history_read ON history
  FOR SELECT TO authenticated
  USING (
    is_staff()
    OR EXISTS (
      SELECT 1 FROM submissions s
      WHERE s.id = history.submission_id
        AND s.scholar_id = my_pid()
    )
  );

CREATE FUNCTION register_scholar(
  p_email TEXT, p_name TEXT, p_sid TEXT, p_program INT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  pid UUID;
BEGIN
  IF NOT is_staff() THEN
    RAISE EXCEPTION 'Access denied: staff only';
  END IF;
  IF coalesce(trim(p_email), '') = ''
     OR coalesce(trim(p_name), '') = ''
     OR coalesce(trim(p_sid), '') = '' THEN
    RAISE EXCEPTION 'Email, name and student ID are required';
  END IF;

  INSERT INTO profiles (email, full_name, student_id, role)
  VALUES (lower(trim(p_email)), trim(p_name), trim(p_sid), 'scholar')
  RETURNING id INTO pid;

  INSERT INTO assignments (scholar_id, program_id)
  VALUES (pid, p_program);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Duplicate: email or student ID is already registered';
END
$$;

CREATE FUNCTION submit_grades(
  p_year TEXT, p_sem INT, p_gwa NUMERIC,
  p_units INT, p_failed INT, p_inc INT, p_drop INT, p_ev TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  pid UUID := my_pid();
  sid UUID;
BEGIN
  IF pid IS NULL OR is_staff() THEN
    RAISE EXCEPTION 'Only scholars can submit grades';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM assignments WHERE scholar_id = pid) THEN
    RAISE EXCEPTION 'You are not assigned to a scholarship program';
  END IF;
  IF p_year IS NULL OR p_year !~ '^\d{4}-\d{4}$' THEN
    RAISE EXCEPTION 'Academic year must look like 2026-2027';
  END IF;
  IF p_sem NOT IN (1, 2) THEN
    RAISE EXCEPTION 'Semester must be 1 or 2';
  END IF;
  PERFORM chk_input(p_gwa, p_units, p_failed, p_inc, p_drop, p_ev);

  INSERT INTO submissions (
    scholar_id, academic_year, semester, gwa, units,
    failed, inc, dropped, evidence_ref
  )
  VALUES (
    pid, p_year, p_sem, p_gwa, p_units,
    p_failed, p_inc, p_drop, trim(p_ev)
  )
  RETURNING id INTO sid;

  PERFORM log_h(sid, 'Submitted', 'Initial submission');
  RETURN sid;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Duplicate: a submission for % semester % already exists',
      p_year, p_sem;
END
$$;

CREATE FUNCTION resubmit_grades(
  p_id UUID, p_gwa NUMERIC,
  p_units INT, p_failed INT, p_inc INT, p_drop INT, p_ev TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  s submissions;
BEGIN
  SELECT * INTO s FROM submissions WHERE id = p_id AND scholar_id = my_pid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission not found';
  END IF;
  IF s.verification_status <> 'Returned' THEN
    RAISE EXCEPTION 'Only returned submissions can be corrected';
  END IF;
  PERFORM chk_input(p_gwa, p_units, p_failed, p_inc, p_drop, p_ev);

  UPDATE submissions
  SET gwa = p_gwa,
      units = p_units,
      failed = p_failed,
      inc = p_inc,
      dropped = p_drop,
      evidence_ref = trim(p_ev),
      updated_at = now(),
      verification_status = 'Pending',
      verification_reason = NULL,
      compliance_result = 'Not Evaluated',
      deficiency_reasons = '{}',
      renewal_decision = 'None',
      decision_note = NULL
  WHERE id = p_id;

  PERFORM log_h(p_id, 'Resubmitted', 'Corrected and returned to Pending verification');
END
$$;

CREATE FUNCTION verify_submission(p_id UUID, p_status TEXT, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT is_staff() THEN
    RAISE EXCEPTION 'Access denied: staff only';
  END IF;
  IF p_status NOT IN ('Verified', 'Returned') THEN
    RAISE EXCEPTION 'Status must be Verified or Returned';
  END IF;
  IF p_status = 'Returned' AND coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required when returning evidence';
  END IF;

  UPDATE submissions
  SET verification_status = p_status,
      verification_reason = nullif(trim(p_reason), ''),
      compliance_result = 'Not Evaluated',
      deficiency_reasons = '{}',
      renewal_decision = 'None',
      decision_note = NULL
  WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission not found';
  END IF;

  PERFORM log_h(p_id, p_status, coalesce(p_reason, ''));
END
$$;

CREATE FUNCTION evaluate_submission(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  s       submissions;
  p       programs;
  reasons TEXT[] := '{}';
  result  TEXT;
BEGIN
  IF NOT is_staff() THEN
    RAISE EXCEPTION 'Access denied: staff only';
  END IF;

  SELECT * INTO s FROM submissions WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission not found';
  END IF;
  IF s.verification_status <> 'Verified' THEN
    RAISE EXCEPTION 'Blocked: evidence must be Verified before evaluation';
  END IF;

  SELECT pr.* INTO p
  FROM programs pr
  JOIN assignments a ON a.program_id = pr.id
  WHERE a.scholar_id = s.scholar_id;

  IF s.gwa > p.max_gwa THEN
    reasons := reasons || format('GWA %s exceeds maximum %s',
      to_char(s.gwa, 'FM0.00'), to_char(p.max_gwa, 'FM0.00'));
  END IF;
  IF s.units < p.min_units THEN
    reasons := reasons || format('Enrolled units %s below minimum %s',
      s.units, p.min_units);
  END IF;
  IF s.failed > p.max_failed THEN
    reasons := reasons || format('Failed subjects %s exceed allowed %s',
      s.failed, p.max_failed);
  END IF;
  IF s.inc > p.max_inc THEN
    reasons := reasons || format('Incomplete grades %s exceed allowed %s',
      s.inc, p.max_inc);
  END IF;
  IF s.dropped > p.max_dropped THEN
    reasons := reasons || format('Dropped subjects %s exceed allowed %s',
      s.dropped, p.max_dropped);
  END IF;
  IF s.submitted_at > p.deadline THEN
    reasons := reasons || 'Submitted after the deadline'::TEXT;
  END IF;

  result := CASE WHEN cardinality(reasons) = 0 THEN 'Compliant' ELSE 'With Deficiency' END;

  UPDATE submissions
  SET compliance_result = result,
      deficiency_reasons = reasons,
      renewal_decision = 'None',
      decision_note = NULL
  WHERE id = p_id;

  PERFORM log_h(p_id, 'Evaluated',
    result || coalesce(': ' || array_to_string(reasons, '; '), ''));
END
$$;

CREATE FUNCTION decide_renewal(p_id UUID, p_dec TEXT, p_note TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  s submissions;
BEGIN
  IF NOT is_staff() THEN
    RAISE EXCEPTION 'Access denied: staff only';
  END IF;

  SELECT * INTO s FROM submissions WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission not found';
  END IF;
  IF p_dec NOT IN ('Approved', 'Held') THEN
    RAISE EXCEPTION 'Decision must be Approved or Held';
  END IF;
  IF s.verification_status <> 'Verified' THEN
    RAISE EXCEPTION 'Blocked: evidence is not verified';
  END IF;
  IF s.compliance_result = 'Not Evaluated' THEN
    RAISE EXCEPTION 'Blocked: evaluate the submission first';
  END IF;
  IF p_dec = 'Approved' AND s.compliance_result <> 'Compliant' THEN
    RAISE EXCEPTION 'Cannot approve a record With Deficiency';
  END IF;
  IF p_dec = 'Held' AND coalesce(trim(p_note), '') = '' THEN
    RAISE EXCEPTION 'A note is required to hold renewal';
  END IF;

  UPDATE submissions
  SET renewal_decision = p_dec,
      decision_note = nullif(trim(p_note), '')
  WHERE id = p_id;

  PERFORM log_h(p_id, 'Renewal ' || p_dec, coalesce(p_note, ''));
END
$$;
