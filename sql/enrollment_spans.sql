-- Monthly Part A / B / D entitlement and continuous A+B+D spans, from the beneficiary files.
-- (list_value blocks generated for months 01-12; one source row per beneficiary-year.)
--  Part A month: MDCR_ENTLMT_BUYIN_IND in (1, 3, A, C)    Part B month: in (2, 3, B, C)
--  Part D month: PTD_CNTRCT_ID_mm is not empty            Part C: HMO_IND is empty in every row, so not modelled.
CREATE OR REPLACE TABLE enroll_month AS
WITH src AS (
  SELECT BENE_ID, CAST(BENE_ENROLLMT_REF_YR AS INTEGER) AS yr,
         list_value(MDCR_ENTLMT_BUYIN_IND_01, MDCR_ENTLMT_BUYIN_IND_02, MDCR_ENTLMT_BUYIN_IND_03, MDCR_ENTLMT_BUYIN_IND_04, MDCR_ENTLMT_BUYIN_IND_05, MDCR_ENTLMT_BUYIN_IND_06, MDCR_ENTLMT_BUYIN_IND_07, MDCR_ENTLMT_BUYIN_IND_08, MDCR_ENTLMT_BUYIN_IND_09, MDCR_ENTLMT_BUYIN_IND_10, MDCR_ENTLMT_BUYIN_IND_11, MDCR_ENTLMT_BUYIN_IND_12) AS buyin,
         list_value(PTD_CNTRCT_ID_01, PTD_CNTRCT_ID_02, PTD_CNTRCT_ID_03, PTD_CNTRCT_ID_04, PTD_CNTRCT_ID_05, PTD_CNTRCT_ID_06, PTD_CNTRCT_ID_07, PTD_CNTRCT_ID_08, PTD_CNTRCT_ID_09, PTD_CNTRCT_ID_10, PTD_CNTRCT_ID_11, PTD_CNTRCT_ID_12) AS ptd
  FROM bene)
SELECT BENE_ID, make_date(yr, k, 1) AS month_start,
       coalesce(buyin[k] IN ('1','3','A','C'), FALSE) AS part_a,
       coalesce(buyin[k] IN ('2','3','B','C'), FALSE) AS part_b,
       ptd[k] IS NOT NULL AS part_d
FROM src, range(1, 13) AS t(k);

-- Islands of consecutive months with A, B and D all present.
CREATE OR REPLACE TABLE enroll_span AS
WITH x AS (
  SELECT BENE_ID, month_start, year(month_start) * 12 + month(month_start) AS mi
  FROM enroll_month WHERE part_a AND part_b AND part_d),
g AS (SELECT *, mi - row_number() OVER (PARTITION BY BENE_ID ORDER BY mi) AS grp FROM x)
SELECT BENE_ID, min(month_start) AS span_start,
       CAST(max(month_start) + INTERVAL 1 MONTH - INTERVAL 1 DAY AS DATE) AS span_end, count(*) AS n_months
FROM g GROUP BY BENE_ID, grp;

-- Islands of consecutive months with Part A and B (Part D not required): used for the end of intention-to-treat follow-up.
CREATE OR REPLACE TABLE enroll_ab_span AS
WITH x AS (SELECT BENE_ID, month_start, year(month_start) * 12 + month(month_start) AS mi FROM enroll_month WHERE part_a AND part_b),
g AS (SELECT *, mi - row_number() OVER (PARTITION BY BENE_ID ORDER BY mi) AS grp FROM x)
SELECT BENE_ID, min(month_start) AS span_start, CAST(max(month_start) + INTERVAL 1 MONTH - INTERVAL 1 DAY AS DATE) AS span_end
FROM g GROUP BY BENE_ID, grp;
