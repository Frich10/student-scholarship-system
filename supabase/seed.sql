INSERT INTO profiles (email, full_name, student_id, role)
VALUES
  ('staff@test.local', 'Staff Tester',  NULL,        'staff'),
  ('a01@test.local',   'Scholar A01',   '2026-0001', 'scholar'),
  ('a02@test.local',   'Scholar A02',   '2026-0002', 'scholar'),
  ('a03@test.local',   'Scholar A03',   '2026-0003', 'scholar'),
  ('a04@test.local',   'Scholar A04',   '2026-0004', 'scholar'),
  ('a05@test.local',   'Scholar A05',   '2026-0005', 'scholar'),
  ('a06@test.local',   'Scholar A06',   '2026-0006', 'scholar');

INSERT INTO assignments (scholar_id, program_id)
SELECT p.id, (SELECT id FROM programs WHERE name = v.program)
FROM profiles p
JOIN (VALUES
  ('2026-0001', 'Merit Scholar'),
  ('2026-0002', 'Merit Scholar'),
  ('2026-0003', 'Community Scholar'),
  ('2026-0004', 'Community Scholar'),
  ('2026-0005', 'Merit Scholar'),
  ('2026-0006', 'Community Scholar')
) AS v (student_id, program) ON v.student_id = p.student_id;

INSERT INTO submissions (
  scholar_id, academic_year, semester, gwa, units, failed, inc, dropped,
  evidence_ref, submitted_at, verification_status
)
SELECT
  p.id, '2026-2027', 1, v.gwa, v.units, v.failed, v.inc, v.dropped,
  'GRADES-' || v.student_id || '.pdf', v.submitted_at::TIMESTAMPTZ, v.status
FROM profiles p
JOIN (VALUES

  ('2026-0001', 1.75, 18, 0, 0, 0, '2026-10-30 17:00+08', 'Verified'),  
  ('2026-0002', 1.76, 18, 0, 0, 0, '2026-10-29 17:00+08', 'Verified'),  
  ('2026-0003', 2.25, 15, 0, 0, 1, '2026-10-29 17:00+08', 'Verified'),  
  ('2026-0004', 2.25, 14, 0, 1, 0, '2026-10-29 17:00+08', 'Verified'),  
  ('2026-0005', 1.50, 18, 1, 0, 0, '2026-10-30 17:01+08', 'Verified'),  
  ('2026-0006', 2.00, 15, 0, 0, 0, '2026-10-29 17:00+08', 'Pending')    
) AS v (student_id, gwa, units, failed, inc, dropped, submitted_at, status)
  ON v.student_id = p.student_id;
