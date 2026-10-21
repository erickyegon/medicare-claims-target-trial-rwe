/*============================================================================================
  cohort_qc.sas - independent SAS re-derivation of the hypertension cohort attrition table and
  baseline counts (protocol v0.4 Section 5), reconciled against the R output.

  This program was written separately from the R code and uses a different algorithm for the
  enrollment criterion: it counts A+B+D months in the look-back range per candidate instead of
  building continuous spans.

  SETUP (SAS OnDemand for Academics):
    1. Upload to your home folder (Files and Folders pane):
         data/raw/            -> &RAW   (beneficiary_20xx.csv, pde.csv, inpatient.csv, hospice.csv, carrier/, outpatient/)
         codelists/           -> &CL    (ndc_antihypertensive.csv, icd10_hypertension.csv, ndc_resolved.csv)
         qc/cohort/           -> &RQC   (attrition.csv, cohort_baseline_counts.csv, cohort_sensitivity_counts.csv from R)
         sas/import_raw.sas   -> &SASDIR
    2. Edit the four %let paths below, then submit the whole program.
  OUTPUT: &OUT/sas_attrition.csv, &OUT/sas_baseline_counts.csv, and a PASS/FAIL table in the log and results.
  NOT RUN by the author: the program has not been executed in SAS; review the log for notes and warnings.
============================================================================================*/
%let RAW    = /home/YOUR_USER/rwe/data/raw;
%let CL     = /home/YOUR_USER/rwe/codelists;
%let RQC    = /home/YOUR_USER/rwe/qc/cohort;
%let SASDIR = /home/YOUR_USER/rwe/sas;
%let OUT    = /home/YOUR_USER/rwe/qc;
options mprint nosymbolgen nomlogic;

%include "&SASDIR/import_raw.sas";

/* ---- code lists (character, keep leading zeros) ---- */
data ndc_map;
  infile "&CL/ndc_antihypertensive.csv" dsd firstobs=2 truncover lrecl=4096;
  length ndc11 $11 ahtn_class $20 ingredients $200 source $120 dl_date $20;
  input ndc11 ahtn_class ingredients source dl_date;
run;
data htn_codes;
  infile "&CL/icd10_hypertension.csv" dsd firstobs=2 truncover lrecl=4096;
  length role $80 family $80 code $7 description $200 source $120 dl_date $20;
  input role family code description source dl_date;
run;
data ndc_resolved;
  infile "&CL/ndc_resolved.csv" dsd firstobs=2 truncover lrecl=4096;
  length ndc11 $11 source $120 dl_date $20;
  input ndc11 source dl_date;
run;

/* ---- 1. monthly A+B+D entitlement (month index mi = year*12 + month) ---- */
data enroll_m(keep=BENE_ID mi);
  set bene_raw;
  array b{12} $ MDCR_ENTLMT_BUYIN_IND_01-MDCR_ENTLMT_BUYIN_IND_12;
  array p{12} $ PTD_CNTRCT_ID_01-PTD_CNTRCT_ID_12;
  yr = input(BENE_ENROLLMT_REF_YR, 4.);
  do m = 1 to 12;
    a  = (b{m} in ('1','3','A','C'));
    bb = (b{m} in ('2','3','B','C'));
    d  = (not missing(p{m}));
    if a and bb and d then do; mi = yr*12 + m; output; end;
  end;
run;
proc sort data=enroll_m nodupkey; by BENE_ID mi; run;

proc sql;
  create table demo as
  select BENE_ID, min(input(BENE_BIRTH_DT, date11.)) as birth format=date9.,
         max(SEX_IDENT_CD) as sex
  from bene_raw group by BENE_ID;
quit;

/* ---- 2. diagnoses (hypertension codes only), hospice, inpatient stays ---- */
%macro dx_pull(ds, ndx, out);
  data &out(keep=BENE_ID dt);
    if 0 then set htn_codes(keep=code);        /* puts CODE in the PDV so the hash key exists */
    if _n_ = 1 then do;
      declare hash h(dataset:'htn_codes(keep=code)');
      h.defineKey('code'); h.defineDone();
    end;
    set &ds;
    array dxs{*} PRNCPAL_DGNS_CD ICD_DGNS_CD1-ICD_DGNS_CD&ndx;
    dt = input(CLM_FROM_DT, date11.);
    do i = 1 to dim(dxs);
      code = dxs{i};
      if not missing(code) and h.find() = 0 then do; output; leave; end;
    end;
    format dt date9.;
  run;
%mend;
%dx_pull(carrier_raw, 12, dx_c);
%dx_pull(outpatient_raw, 25, dx_o);
%dx_pull(inpatient_raw, 25, dx_i);
data dx_htn; set dx_c dx_o dx_i; run;
proc sort data=dx_htn nodupkey; by BENE_ID dt; run;

data hospice(keep=BENE_ID from_dt thru_dt);
  set hospice_raw; from_dt = input(CLM_FROM_DT, date11.); thru_dt = input(CLM_THRU_DT, date11.); format from_dt thru_dt date9.;
run;
data ip_stay(keep=BENE_ID adm_dt thru_dt);
  set inpatient_raw; adm_dt = input(CLM_ADMSN_DT, date11.); thru_dt = input(CLM_THRU_DT, date11.);
  if not missing(adm_dt); format adm_dt thru_dt date9.;
run;

/* ---- 3. antihypertensive fills and candidate index dates ---- */
data pde_f(keep=BENE_ID fill_dt ndc11);
  set pde_raw; fill_dt = input(SRVC_DT, date11.); ndc11 = PROD_SRVC_ID; format fill_dt date9.;
run;
proc sql;
  create table ahtn_fill as
  select distinct f.BENE_ID, f.fill_dt, m.ahtn_class
  from pde_f f inner join ndc_map m on f.ndc11 = m.ndc11;

  create table study_day as
  select BENE_ID, fill_dt as idx format=date9.,
         max(ahtn_class = 'ACEI') as acei, max(ahtn_class = 'THIAZIDE') as thiazide
  from ahtn_fill
  where ahtn_class in ('ACEI','THIAZIDE') and fill_dt >= '01MAR2016'd
  group by BENE_ID, fill_dt;

  /* criterion 1: new user */
  create table cand_nu as
  select s.* from study_day s
  where not exists (select 1 from ahtn_fill a where a.BENE_ID = s.BENE_ID and a.fill_dt between s.idx - 365 and s.idx - 1);

  /* criteria 2-7 as 0/1 flags */
  create table cand_flags as
  select c.BENE_ID, c.idx, c.acei, c.thiazide,
    case when c.idx >= intnx('year', d.birth, 65, 'sameday') then 1 else 0 end as f_age,
    case when (select count(*) from enroll_m e where e.BENE_ID = c.BENE_ID
                 and e.mi between (year(c.idx - 365)*12 + month(c.idx - 365)) and (year(c.idx)*12 + month(c.idx)))
              = ((year(c.idx)*12 + month(c.idx)) - (year(c.idx - 365)*12 + month(c.idx - 365)) + 1)
         then 1 else 0 end as f_enroll,
    case when exists (select 1 from dx_htn x where x.BENE_ID = c.BENE_ID and x.dt between c.idx - 365 and c.idx) then 1 else 0 end as f_htn,   /* A-009: days -365 to 0 */
    case when c.acei = 1 and c.thiazide = 1 then 0 else 1 end as f_notboth,
    case when exists (select 1 from ahtn_fill a where a.BENE_ID = c.BENE_ID and a.fill_dt = c.idx and a.ahtn_class not in ('ACEI','THIAZIDE')) then 0 else 1 end as f_nocostart,   /* A-010 */
    case when exists (select 1 from hospice h where h.BENE_ID = c.BENE_ID and h.from_dt <= c.idx - 1 and h.thru_dt >= c.idx - 365) then 0 else 1 end as f_nohospice,
    case when exists (select 1 from ip_stay s where s.BENE_ID = c.BENE_ID and s.adm_dt <= c.idx and s.thru_dt >= c.idx) then 0 else 1 end as f_noinpt
  from cand_nu c inner join demo d on d.BENE_ID = c.BENE_ID;
quit;

/* ---- 4. sequential attrition ---- */
%macro count_step(step, label, where=1);
  proc sql noprint;
    select count(*), count(distinct BENE_ID) into :n_e trimmed, :n_p trimmed from cand_flags where &where;
  quit;
  data _row; step=&step; length description $120; description="&label"; n_episodes=&n_e; n_persons=&n_p; run;
  proc append base=sas_attr data=_row force; run;
%mend;

proc sql noprint;
  select count(distinct BENE_ID) into :n_bene trimmed from demo;
  select count(*), count(distinct BENE_ID) into :n_sd_e trimmed, :n_sd_p trimmed from study_day;
  select count(*), count(distinct BENE_ID) into :n_nu_e trimmed, :n_nu_p trimmed from cand_nu;
quit;
proc datasets lib=work nolist; delete sas_attr; quit;
data sas_attr;
  length description $120; step=0; description='Beneficiaries in the beneficiary files'; n_episodes=.; n_persons=&n_bene; output;
  step=1; description='Candidate index dates (study-drug fills on/after 2016-03-01)'; n_episodes=&n_sd_e; n_persons=&n_sd_p; output;
  step=2; description='New user'; n_episodes=&n_nu_e; n_persons=&n_nu_p; output;
run;
%count_step(3, Age 65 or older, where=f_age=1);
%count_step(4, Continuous A+B+D, where=f_age=1 and f_enroll=1);
%count_step(5, Hypertension diagnosis, where=f_age=1 and f_enroll=1 and f_htn=1);
%count_step(6, Not both study drugs, where=f_age=1 and f_enroll=1 and f_htn=1 and f_notboth=1);
%count_step(7, No other class on index date, where=f_age=1 and f_enroll=1 and f_htn=1 and f_notboth=1 and f_nocostart=1);
%count_step(8, No hospice, where=f_age=1 and f_enroll=1 and f_htn=1 and f_notboth=1 and f_nocostart=1 and f_nohospice=1);
%count_step(9, No inpatient overlap, where=f_age=1 and f_enroll=1 and f_htn=1 and f_notboth=1 and f_nocostart=1 and f_nohospice=1 and f_noinpt=1);

/* final cohort: first qualifying episode per beneficiary */
proc sql;
  create table cohort as
  select BENE_ID, min(idx) as idx format=date9. from cand_flags
  where f_age=1 and f_enroll=1 and f_htn=1 and f_notboth=1 and f_nocostart=1 and f_nohospice=1 and f_noinpt=1 group by BENE_ID;
  create table cohort_arm as
  select h.BENE_ID, h.idx, case when c.acei = 1 then 'ACEI' else 'THIAZIDE' end as arm length=10
  from cohort h inner join cand_flags c on c.BENE_ID = h.BENE_ID and c.idx = h.idx;
  select count(*) into :n_final trimmed from cohort_arm;
quit;
data _row; step=10; length description $120; description='First qualifying episode per beneficiary (final cohort)'; n_episodes=&n_final; n_persons=&n_final; run;
proc append base=sas_attr data=_row force; run;

/* ---- 5. baseline counts by arm ---- */
proc sql;
  create table base_age as
  select a.arm, 'age_group' as variable length=20,
    case when age <= 74 then '65-74' when age <= 84 then '75-84' else '85+' end as level length=20, count(*) as n
  from (select h.arm, intck('year', d.birth, h.idx, 'continuous') as age
        from cohort_arm h inner join demo d on d.BENE_ID = h.BENE_ID) a
  group by a.arm, calculated level;
  create table base_sex as
  select h.arm, 'sex' as variable length=20,
    case when d.sex = '1' then 'male' when d.sex = '2' then 'female' else 'unknown' end as level length=20, count(*) as n
  from cohort_arm h inner join demo d on d.BENE_ID = h.BENE_ID
  group by h.arm, calculated level;
quit;
data sas_base; set base_age base_sex; run;

/* ---- 6. reconcile with R ---- */
proc import datafile="&RQC/attrition.csv" out=r_attr dbms=csv replace; guessingrows=max; run;
proc import datafile="&RQC/cohort_baseline_counts.csv" out=r_base dbms=csv replace; guessingrows=max; run;

proc sql;
  create table recon_attr as
  select s.step, s.description, r.n_episodes as r_episodes, s.n_episodes as sas_episodes, r.n_persons as r_persons, s.n_persons as sas_persons,
         case when s.n_persons = r.n_persons and (s.n_episodes = r.n_episodes or (s.n_episodes is null and r.n_episodes is null)) then 'PASS' else 'FAIL' end as result length=4
  from sas_attr s left join r_attr r on s.step = r.step order by s.step;
  create table recon_base as
  select coalesce(s.arm, r.arm) as arm, coalesce(s.variable, r.variable) as variable, coalesce(s.level, r.level) as level,
         r.n as r_n, s.n as sas_n, case when s.n = r.n then 'PASS' else 'FAIL' end as result length=4
  from sas_base s full join r_base r on s.arm = r.arm and s.variable = r.variable and s.level = r.level
  order by 1, 2, 3;
  select sum(result = 'FAIL') as attrition_fails, count(*) as attrition_rows from recon_attr;
  select sum(result = 'FAIL') as baseline_fails, count(*) as baseline_rows from recon_base;
quit;
title 'Attrition: R vs SAS'; proc print data=recon_attr noobs; run;
title 'Baseline counts: R vs SAS'; proc print data=recon_base noobs; run;
title;

proc export data=sas_attr outfile="&OUT/sas_attrition.csv" dbms=csv replace; run;
proc export data=sas_base outfile="&OUT/sas_baseline_counts.csv" dbms=csv replace; run;
proc export data=recon_attr outfile="&OUT/r_vs_sas_attrition.csv" dbms=csv replace; run;
proc export data=recon_base outfile="&OUT/r_vs_sas_baseline.csv" dbms=csv replace; run;
