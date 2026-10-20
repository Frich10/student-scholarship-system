# Student Scholarship Monitoring and Academic Compliance System

SAD Laboratory Midterm, Section A. Static HTML/CSS/JavaScript front end with Supabase (Postgres, Auth, row-level security). No build step.

## Project structure

```text
SAD_Exam_Section_A_StudentID/
├── index.html          Page markup
├── styles.css          Styles (light and dark themes)
├── app.js              Client logic
├── config.js           Supabase URL and anon key
└── supabase/
    ├── schema.sql      Tables, RLS policies, business functions
    └── seed.sql        Synthetic records A01 to A06
```

## Setup

1. Create a Supabase project. Under Auth, keep **Confirm email** enabled (roles are resolved from the verified email).
2. In the SQL Editor, run `supabase/schema.sql`, then `supabase/seed.sql`.
3. Under Auth > Users, create and confirm `staff@test.local` and `a01@test.local` to `a06@test.local`. Share passwords privately with the instructor only.
4. Edit `config.js` with your project URL and **anon** key. Never use the service-role key.
5. Serve locally: `python -m http.server 8000`, then open <http://localhost:8000>. For hosting, use GitHub Pages.

## Architecture

- Clients have read-only access under RLS. Scholars read only their own rows; staff read all.
- Every write goes through a `SECURITY DEFINER` function that checks role and state: `submit_grades`, `resubmit_grades`, `verify_submission`, `evaluate_submission`, `decide_renewal`, `register_scholar`.
- Thresholds and the deadline are read from the `programs` table at evaluation time.
- Submission status, compliance result, and renewal decision are separate columns.
- Duplicate prevention: unique `(scholar_id, academic_year, semester)`.
- Audit trail: the `history` table records action, actor, detail, and timestamp. Resubmission keeps the original `submitted_at`.

## Test guide

| ID | Action | Expected |
|----|--------|----------|
| TC01 | Staff evaluate A01 | Compliant |
| TC02 | Staff evaluate A02 | With Deficiency (GWA) |
| TC03 | Staff evaluate A03 | Compliant |
| TC04 | Staff evaluate A04 | Deficiency: units and incomplete grade |
| TC05 | Staff evaluate A05 | Deficiency: failed subject and late |
| TC06 | Evaluate and approve A06 | Both blocked |
| TC07 | Scholar submits a duplicate term, GWA 0.50, or a negative count | Rejected with message |
| TC08 | Scholar reads another record or calls `verify_submission` | Denied by backend |
| TC09 | Return, correct, resubmit, refresh | Pending, history kept |
| TC10 | Approve A01, hold A05 | Allowed; scholar cannot decide |

Record actual results and screenshots in the results table. Known defects: _to be completed after testing._
