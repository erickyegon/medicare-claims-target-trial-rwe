# Pipeline wiring (targets). Each target runs one program and tracks its output files, so changing a script or an upstream output
# re-runs only what depends on it. Run with: Rscript -e "targets::tar_make()".
# Reference data that needs the network (FDA NDC directory, RxNorm/RxClass lookups, CCW and ResDAC tables) is built once by the Python scripts in
# codelists/build/ (see the README); their outputs live in data/ref and are inputs here.
# Note: several steps add tables to the same DuckDB file, so only a clean tar_make() (no _targets/ cache) is a faithful full rebuild.
library(targets)
run <- function(cmd, args, outputs, ...) {          # `...` only creates the dependency on upstream targets
  status <- system2(cmd, args)
  if (status != 0) stop(paste(c(cmd, args), collapse = " "), " failed (exit ", status, ")")
  outputs
}
rscript <- file.path(R.home("bin"), "Rscript")
tar_option_set(format = "file")
list(
  tar_target(ingest,        run(rscript, "R/01_ingest.R", "data/medicare.duckdb")),
  tar_target(enrollment,    run(rscript, "R/04_enrollment.R", "data/medicare.duckdb", ingest)),
  tar_target(codelists_icd, run(rscript, "R/03_codelists.R", c("codelists/icd10_bronchitis.csv", "codelists/icd10_exclusions.csv", "codelists/ndc_antibiotics.csv", "qc/ndc_match_summary.csv"), ingest)),
  tar_target(code_lists,    run(rscript, "R/06_codelists_ahtn.R", c("codelists/antihypertensive_ingredients.csv", "codelists/icd10_hypertension.csv", "codelists/ndc_antihypertensive.csv", "codelists/ndc_resolved.csv"), ingest)),
  tar_target(profile_extra, run(rscript, "R/02b_profile_extra.R", c("qc/profile_ip_overall.csv", "qc/profile_op_rev_hcpcs.csv"), ingest)),
  tar_target(scan,          run(rscript, "R/05_indication_scan.R", c("qc/scan/acute_scan.csv", "qc/scan/candidate_outcomes.csv"), enrollment, code_lists, codelists_icd)),
  tar_target(cohort,        run(rscript, "R/06_cohort.R", c("qc/cohort/attrition.csv", "qc/cohort/arm_sizes.csv"), enrollment, code_lists)),
  tar_target(followup,      run(rscript, "R/07_followup.R", c("qc/cohort/crude_events.csv", "qc/cohort/timing_counts.csv"), cohort)),
  tar_target(analysis,      run(rscript, "R/09_analysis.R", c("qc/analysis/primary_results.csv", "qc/analysis/sensitivity_results.csv"), followup)),
  tar_target(pooled30,      run(rscript, "R/09b_pooled30_df_check.R", "qc/analysis/pooled30_df_check.csv", analysis)),
  tar_target(crosscheck,    run("python", "qc/python_crosscheck.py", c("qc/cohort/python_vs_r_attrition.csv", "qc/cohort/python_vs_r_followup.csv"), followup)),
  tar_target(facts,         run(rscript, "R/10_manifest_facts.R", c("qc/feasibility_facts.csv", "qc/dataset_version.txt", "qc/cohort/refill_pattern.csv"), analysis, scan)),
  tar_target(tfl,           run(rscript, "R/11_tfl.R", "output/tfl/provenance.csv", analysis, facts, crosscheck)),
  tar_target(docs, {
    tfl; scan; profile_extra; pooled30
    for (f in c("docs/feasibility.qmd", "docs/sap.qmd", "docs/study_report.qmd", "qc/indication_scan.qmd", "qc/profiling.qmd"))
      if (system2("quarto", c("render", f)) != 0) stop("quarto render failed: ", f)
    c("docs/feasibility.html", "docs/sap.html", "docs/study_report.html", "qc/indication_scan.html", "qc/profiling.html")
  }),
  tar_target(narrative_audit, run("python", "qc/narrative_audit.py", "qc/narrative_audit.csv", docs))
)
