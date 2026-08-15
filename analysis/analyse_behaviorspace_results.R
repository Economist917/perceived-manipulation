# ============================================================
# Analyse BehaviorSpace results
# Perceived Manipulation and Epistemic Trust ABM
# ============================================================

# Run this script from the project root:
#   Rscript analysis/analyse_behaviorspace_results.R
#
# Optional arguments:
#   Rscript analysis/analyse_behaviorspace_results.R \
#     data/behaviorspace_results.csv results figures

required_packages <- c("dplyr", "tidyr", "readr", "ggplot2")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0) {
  stop(
    paste0(
      "Install the following R packages before running this script: ",
      paste(missing_packages, collapse = ", ")
    ),
    call. = FALSE
  )
}

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

input_file <- if (length(args) >= 1) {
  args[[1]]
} else {
  file.path("behaviorspace_results")
}

results_dir <- if (length(args) >= 2) args[[2]] else "results"
figures_dir <- if (length(args) >= 3) args[[3]] else "figures"

if (!file.exists(input_file)) {
  stop("BehaviorSpace file not found: ", input_file, call. = FALSE)
}

dir.create(results_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

# NetLogo places several metadata rows before the CSV column names.
# Locate the header dynamically so that the script remains robust to
# differences in metadata length across NetLogo versions.
file_lines <- readLines(input_file, warn = FALSE)
header_line <- grep('^"?\\[run number\\]"?', file_lines)[1]

if (is.na(header_line)) {
  stop("Could not locate the BehaviorSpace table header.", call. = FALSE)
}

raw_results <- read.csv(
  input_file,
  skip = header_line - 1,
  check.names = FALSE,
  stringsAsFactors = FALSE
)

required_columns <- c(
  "[run number]",
  "average-manipulation-sensitivity",
  "confidence-bound",
  "learning-rate",
  "population",
  "mean-trust",
  "opinion-fragmentation",
  "manipulation-rate",
  "update-rate",
  "ticks"
)

missing_columns <- setdiff(required_columns, names(raw_results))

if (length(missing_columns) > 0) {
  stop(
    "Missing required columns: ",
    paste(missing_columns, collapse = ", "),
    call. = FALSE
  )
}

results <- raw_results %>%
  rename(
    run_number = `[run number]`,
    sensitivity = `average-manipulation-sensitivity`,
    confidence = `confidence-bound`,
    learning_rate = `learning-rate`,
    mean_trust = `mean-trust`,
    fragmentation = `opinion-fragmentation`,
    manipulation_rate = `manipulation-rate`,
    update_rate = `update-rate`
  ) %>%
  group_by(run_number) %>%
  slice_max(order_by = ticks, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  arrange(sensitivity, confidence, run_number)

# ------------------------------------------------------------
# Data-quality checks
# ------------------------------------------------------------

cell_counts <- results %>%
  count(sensitivity, confidence, name = "runs")

quality_summary <- tibble(
  total_rows = nrow(results),
  unique_runs = n_distinct(results$run_number),
  sensitivity_levels = n_distinct(results$sensitivity),
  confidence_levels = n_distinct(results$confidence),
  minimum_repetitions_per_cell = min(cell_counts$runs),
  maximum_repetitions_per_cell = max(cell_counts$runs),
  minimum_tick = min(results$ticks),
  maximum_tick = max(results$ticks),
  missing_values = sum(is.na(results))
)

write_csv(
  quality_summary,
  file.path(results_dir, "data_quality_summary.csv")
)

write_csv(
  cell_counts,
  file.path(results_dir, "cell_counts.csv")
)

if (n_distinct(results$run_number) != 270) {
  warning("Expected 270 unique runs, but found ", n_distinct(results$run_number), ".")
}

if (any(cell_counts$runs != 30)) {
  warning("Not every parameter combination contains 30 repetitions.")
}

if (any(results$ticks != 300)) {
  warning("At least one final observation was not recorded at tick 300.")
}

# ------------------------------------------------------------
# Descriptive statistics and 95% confidence intervals
# ------------------------------------------------------------

outcome_labels <- c(
  mean_trust = "Mean epistemic trust",
  fragmentation = "Opinion fragmentation",
  manipulation_rate = "Perceived manipulation rate",
  update_rate = "Opinion-update rate"
)

summary_long <- results %>%
  pivot_longer(
    cols = all_of(names(outcome_labels)),
    names_to = "outcome",
    values_to = "value"
  ) %>%
  group_by(sensitivity, confidence, outcome) %>%
  summarise(
    n = n(),
    mean = mean(value),
    sd = sd(value),
    se = sd / sqrt(n),
    ci_low = mean - qt(0.975, df = n - 1) * se,
    ci_high = mean + qt(0.975, df = n - 1) * se,
    .groups = "drop"
  ) %>%
  mutate(outcome_label = unname(outcome_labels[outcome]))

write_csv(
  summary_long,
  file.path(results_dir, "summary_by_condition.csv")
)

# ------------------------------------------------------------
# Balanced two-factor ANOVA
#
# Parameters are treated as experimental levels rather than assuming that
# their effects are linear. P-values describe variation among simulation
# runs; they are not evidence about real citizens or institutions.
# ------------------------------------------------------------

model_data <- results %>%
  mutate(
    sensitivity_factor = factor(sensitivity),
    confidence_factor = factor(confidence)
  )

run_factorial_anova <- function(outcome_name) {
  model_formula <- as.formula(
    paste(outcome_name, "~ sensitivity_factor * confidence_factor")
  )
  
  fitted_model <- lm(model_formula, data = model_data)
  model_anova <- anova(fitted_model)
  
  anova_table <- data.frame(
    outcome = outcome_name,
    term = rownames(model_anova),
    df = model_anova$Df,
    sum_sq = model_anova$`Sum Sq`,
    mean_sq = model_anova$`Mean Sq`,
    f_value = model_anova$`F value`,
    p_value = model_anova$`Pr(>F)`,
    row.names = NULL,
    check.names = FALSE
  )
  
  residual_ss <- anova_table$sum_sq[anova_table$term == "Residuals"]
  
  anova_table %>%
    mutate(
      partial_eta_squared = if_else(
        term == "Residuals",
        NA_real_,
        sum_sq / (sum_sq + residual_ss)
      )
    )
}

anova_results <- bind_rows(
  lapply(names(outcome_labels), run_factorial_anova)
)

write_csv(
  anova_results,
  file.path(results_dir, "factorial_anova_results.csv")
)

# ------------------------------------------------------------
# Interaction plots with 95% confidence intervals
# ------------------------------------------------------------

confidence_palette <- c(
  "0.2" = "#1F4E79",
  "0.5" = "#C28E0E",
  "0.8" = "#B44C7A"
)

make_interaction_plot <- function(
    outcome_name,
    plot_title,
    y_axis_title,
    output_filename,
    y_limits) {
  
  plot_data <- summary_long %>%
    filter(outcome == outcome_name) %>%
    mutate(
      sensitivity = factor(sensitivity, levels = c(0.1, 0.5, 0.9)),
      confidence = factor(confidence, levels = c(0.2, 0.5, 0.8))
    )
  
  figure <- ggplot(
    plot_data,
    aes(
      x = sensitivity,
      y = mean,
      colour = confidence,
      group = confidence
    )
  ) +
    geom_errorbar(
      aes(ymin = ci_low, ymax = ci_high),
      width = 0.08,
      linewidth = 0.65
    ) +
    geom_line(linewidth = 0.9) +
    geom_point(size = 2.8) +
    scale_colour_manual(
      values = confidence_palette,
      name = "Confidence bound"
    ) +
    coord_cartesian(ylim = y_limits) +
    labs(
      title = plot_title,
      subtitle = paste(
        "Mean and 95% CI across 30 runs per condition;",
        "100 agents, 300 ticks, learning rate = 0.35"
      ),
      x = "Average manipulation sensitivity",
      y = y_axis_title,
      caption = "Source: BehaviorSpace simulation output."
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold", colour = "#222222"),
      plot.subtitle = element_text(colour = "#555555"),
      plot.caption = element_text(colour = "#666666", hjust = 0),
      panel.grid.minor = element_blank(),
      panel.grid.major.x = element_blank(),
      axis.title = element_text(colour = "#333333"),
      legend.position = "top"
    )
  
  ggsave(
    filename = file.path(figures_dir, output_filename),
    plot = figure,
    width = 8,
    height = 5.4,
    dpi = 300,
    bg = "white"
  )
}

make_interaction_plot(
  outcome_name = "mean_trust",
  plot_title = "Mean epistemic trust across parameter combinations",
  y_axis_title = "Mean trust at tick 300",
  output_filename = "Figure_1_mean_trust.png",
  y_limits = c(0, 1.05)
)

make_interaction_plot(
  outcome_name = "fragmentation",
  plot_title = "Opinion fragmentation across parameter combinations",
  y_axis_title = "Opinion variance at tick 300",
  output_filename = "Figure_2_opinion_fragmentation.png",
  y_limits = c(0, 0.09)
)

message("Analysis completed.")
message("Results written to: ", normalizePath(results_dir))
message("Figures written to: ", normalizePath(figures_dir))