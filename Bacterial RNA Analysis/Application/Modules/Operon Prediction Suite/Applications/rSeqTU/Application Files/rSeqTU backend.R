###############################################################################
# Complete rSeqTU pipeline for a bacterial chromosome on Windows
#
# Dataset used while developing this script:
#   Organism: Amycolatopsis sp. TNS106
#   Chromosome accession: NZ_CP024972.1
#   BAM reference name: gi|2073468833|ref|NZ_CP024972.1|
#   Chromosome length: 8,806,031 bp
#
# Workflow:
#   1. Check/install all required packages and rSeqTU
#   2. Check, index, or coordinate-sort/index the BAM
#   3. Extract strand-specific per-base coverage for one BAM reference
#   4. Select and validate the complete chromosome FASTA
#   5. Create an rSeqTU-compatible chromosome-only gene GFF
#   6. Remove coordinates that rSeqTU cannot represent, including an
#      origin-spanning gene on a circular chromosome
#   7. Generate rSeqTU feature/training matrices
#   8. Run TU_SVM
#   9. Write one final plot table and one strand-aware bedGraph
#  10. Delete all generated intermediate files after successful completion,
#      while retaining the cleaned SVM GFF and BAM index
#
# IMPORTANT:
#   - Use forward slashes in Windows paths.
#   - INPUT_FASTA must be a complete genomic FASTA, not a CDS/RNA FASTA.
#   - Keep one sample per output folder because rSeqTU writes several fixed
#     matrix filenames.
#   - Set SWAP_STRANDS = TRUE only when your stranded RNA-seq protocol requires
#     reversing the BAM read strand relative to the transcript strand.
###############################################################################


# =============================================================================
# 0. GUI/COMMAND-LINE SETTINGS
# =============================================================================

arguments <- commandArgs(trailingOnly = TRUE)

if (length(arguments) != 1L) {
  stop(
    "This backend expects one GUI configuration file.",
    call. = FALSE
  )
}

CONFIG_FILE <- normalizePath(
  arguments[1],
  winslash = "/",
  mustWork = TRUE
)

configuration <- read.delim(
  CONFIG_FILE,
  header = FALSE,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE,
  fill = TRUE,
  col.names = c("key", "value")
)

configuration$value <- trimws(configuration$value)
configuration <- configuration[
  !is.na(configuration$key) &
    !is.na(configuration$value) &
    nzchar(configuration$key),
  ,
  drop = FALSE
]

get_config_value <- function(key) {
  selected <- configuration$value[configuration$key == key]

  if (length(selected) != 1L || !nzchar(selected)) {
    stop(
      "Missing or duplicated GUI setting: ",
      key,
      call. = FALSE
    )
  }

  selected
}

get_config_optional_value <- function(key, default = "") {
  selected <- configuration$value[configuration$key == key]

  if (
    length(selected) == 0L ||
      all(is.na(selected))
  ) {
    return(default)
  }

  if (length(selected) != 1L) {
    stop(
      "Duplicated GUI setting: ",
      key,
      call. = FALSE
    )
  }

  selected <- trimws(selected)

  if (is.na(selected) || !nzchar(selected)) {
    return(default)
  }

  selected
}

get_config_logical <- function(key, default = FALSE) {
  default_text <- if (isTRUE(default)) "true" else "false"
  value <- tolower(get_config_optional_value(key, default_text))

  if (value %in% c("true", "1", "yes", "y", "on")) {
    return(TRUE)
  }

  if (value %in% c("false", "0", "no", "n", "off")) {
    return(FALSE)
  }

  stop(
    key,
    " must be true or false.",
    call. = FALSE
  )
}

get_config_integer <- function(
  key,
  default,
  minimum = 0L,
  maximum = 255L
) {
  value <- get_config_optional_value(
    key,
    as.character(default)
  )

  parsed <- suppressWarnings(as.integer(value))

  if (
    is.na(parsed) ||
      parsed < minimum ||
      parsed > maximum
  ) {
    stop(
      key,
      " must be an integer from ",
      minimum,
      " to ",
      maximum,
      ".",
      call. = FALSE
    )
  }

  parsed
}

INPUT_BAM <- get_config_value("BAM")
INPUT_GFF <- get_config_value("GFF")
INPUT_FASTA <- get_config_value("FASTA")
OUTPUT_DIR <- get_config_value("OUTPUT")

CHROMOSOME_INPUT <- get_config_optional_value(
  "CHROMOSOME",
  ""
)

GUI_STATUS_FILE <- get_config_optional_value(
  "STATUS_FILE",
  file.path(
    tempdir(),
    paste0(
      "rSeqTU_status_",
      Sys.getpid(),
      ".tsv"
    )
  )
)

# Internal prefix used by rSeqTU. It remains shell-safe because rSeqTU creates
# several fixed intermediate filenames from this value.
PREFIX <- tools::file_path_sans_ext(
  basename(INPUT_BAM)
)

PREFIX <- gsub(
  "[^A-Za-z0-9_.-]",
  "_",
  PREFIX
)

if (!nzchar(PREFIX)) {
  PREFIX <- "rSeqTU_sample"
}

# Human-readable prefix used only for retained result files. Underscores in the
# BAM sample name are displayed as spaces.
DISPLAY_PREFIX <- tools::file_path_sans_ext(
  basename(INPUT_BAM)
)

DISPLAY_PREFIX <- gsub(
  "_+",
  " ",
  DISPLAY_PREFIX
)

DISPLAY_PREFIX <- gsub(
  '[<>:"/\\\\|?*]',
  " ",
  DISPLAY_PREFIX
)

DISPLAY_PREFIX <- gsub(
  "\\s+",
  " ",
  trimws(DISPLAY_PREFIX)
)

if (!nzchar(DISPLAY_PREFIX)) {
  DISPLAY_PREFIX <- "rSeqTU sample"
}

# When the chromosome box is blank, the first FASTA record and the first
# GFF/GFF3 sequence ID are used. A typed value overrides this behavior.
ACCESSION <- if (nzchar(CHROMOSOME_INPUT)) {
  CHROMOSOME_INPUT
} else {
  NULL
}

NA_FILE <- file.path(
  OUTPUT_DIR,
  paste0(PREFIX, ".NA")
)

# GUI defaults: a complete fresh run with cleanup.
INSTALL_PACKAGES <- TRUE
OVERWRITE <- TRUE
RUN_QC_STEP <- TRUE
RUN_FEATURE_STEP <- TRUE
RUN_SVM_STEP <- TRUE
DELETE_INTERMEDIATE_FILES <- TRUE

MIN_MAPQ <- get_config_integer(
  "MIN_MAPQ",
  default = 15L,
  minimum = 0L,
  maximum = 255L
)

MIN_BASE_QUALITY <- get_config_integer(
  "MIN_BASE_QUALITY",
  default = 10L,
  minimum = 0L,
  maximum = 255L
)

COPY_BAM_BAI_TO_IGV <- get_config_logical(
  "COPY_BAM_BAI_TO_IGV",
  default = FALSE
)

# This preserves the strand behavior of the validated ABN1 workflow.
SWAP_STRANDS <- FALSE

RANDOM_SEED <- 123L


# =============================================================================
# 1. GENERAL HELPERS
# =============================================================================

message_section <- function(title) {
  cat(
    "\n",
    paste(rep("=", 78), collapse = ""),
    "\n",
    title,
    "\n",
    paste(rep("=", 78), collapse = ""),
    "\n",
    sep = ""
  )
}


GUI_CURRENT_STEP <- 1L
GUI_CURRENT_PERCENT <- 0L
GUI_CURRENT_MESSAGE <- "Starting"

write_gui_status <- function(
  workflow_step,
  percent,
  state,
  message
) {
  GUI_CURRENT_STEP <<- as.integer(workflow_step)
  GUI_CURRENT_PERCENT <<- as.integer(percent)
  GUI_CURRENT_MESSAGE <<- as.character(message)

  status_data <- data.frame(
    key = c(
      "workflow_step",
      "percent",
      "state",
      "message",
      "time"
    ),
    value = c(
      as.character(GUI_CURRENT_STEP),
      as.character(GUI_CURRENT_PERCENT),
      as.character(state),
      GUI_CURRENT_MESSAGE,
      format(
        Sys.time(),
        "%Y-%m-%d %H:%M:%S"
      )
    ),
    stringsAsFactors = FALSE
  )

  temporary_status <- paste0(
    GUI_STATUS_FILE,
    ".tmp"
  )

  write.table(
    status_data,
    file = temporary_status,
    sep = "\t",
    quote = FALSE,
    row.names = FALSE,
    col.names = FALSE
  )

  if (file.exists(GUI_STATUS_FILE)) {
    unlink(
      GUI_STATUS_FILE,
      force = TRUE
    )
  }

  renamed <- file.rename(
    temporary_status,
    GUI_STATUS_FILE
  )

  if (!renamed) {
    file.copy(
      temporary_status,
      GUI_STATUS_FILE,
      overwrite = TRUE
    )

    unlink(
      temporary_status,
      force = TRUE
    )
  }

  cat(
    sprintf(
      "\n[GUI_STATUS] step=%d percent=%d state=%s message=%s\n",
      GUI_CURRENT_STEP,
      GUI_CURRENT_PERCENT,
      state,
      GUI_CURRENT_MESSAGE
    )
  )

  flush.console()
  invisible(NULL)
}

options(
  error = function() {
    try(
      write_gui_status(
        GUI_CURRENT_STEP,
        GUI_CURRENT_PERCENT,
        "Error",
        paste0(
          "Pipeline stopped during: ",
          GUI_CURRENT_MESSAGE
        )
      ),
      silent = TRUE
    )

    q(
      save = "no",
      status = 1L,
      runLast = FALSE
    )
  }
)

assert_file <- function(path, label = "File") {
  if (!file.exists(path)) {
    stop(label, " does not exist: ", path, call. = FALSE)
  }
  invisible(normalizePath(path, winslash = "/", mustWork = TRUE))
}

assert_directory <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE, showWarnings = FALSE)
  }

  if (!dir.exists(path)) {
    stop("Could not create output directory: ", path, call. = FALSE)
  }

  invisible(normalizePath(path, winslash = "/", mustWork = TRUE))
}

safe_file_size <- function(paths) {
  info <- file.info(paths)
  round(info$size / 1024^2, 3)
}

use_working_directory <- function(directory, expression) {
  old_directory <- getwd()
  on.exit(setwd(old_directory), add = TRUE)
  setwd(directory)
  force(expression)
}

quiet_require_namespace <- function(package) {
  suppressWarnings(
    suppressPackageStartupMessages(
      requireNamespace(
        package,
        quietly = TRUE
      )
    )
  )
}

package_status <- function(packages) {
  data.frame(
    package = packages,
    installed = vapply(
      packages,
      quiet_require_namespace,
      logical(1)
    ),
    row.names = NULL,
    stringsAsFactors = FALSE
  )
}


# =============================================================================
# 2. PACKAGE INSTALLATION AND CHECKS
# =============================================================================

install_rSeqTU <- function() {
  if (quiet_require_namespace("rSeqTU")) {
    return(invisible(TRUE))
  }

  if (!quiet_require_namespace("remotes")) {
    install.packages(
      "remotes",
      repos = "https://cloud.r-project.org"
    )
  }

  message("Installing rSeqTU from shengyongniu/rSeqTU ...")

  github_install_ok <- tryCatch(
    {
      remotes::install_github(
        "shengyongniu/rSeqTU",
        dependencies = FALSE,
        upgrade = "never"
      )
      TRUE
    },
    error = function(e) {
      warning(
        "remotes::install_github() failed: ",
        conditionMessage(e),
        "\nTrying direct R CMD INSTALL instead.",
        call. = FALSE
      )
      FALSE
    }
  )

  if (github_install_ok && quiet_require_namespace("rSeqTU")) {
    return(invisible(TRUE))
  }

  # Fallback used because this old package can be difficult for remotes to
  # install on some Windows systems.
  zip_file <- tempfile(fileext = ".zip")
  extract_dir <- tempfile(pattern = "rSeqTU_")
  dir.create(extract_dir, recursive = TRUE)

  download.file(
    "https://github.com/shengyongniu/rSeqTU/archive/refs/heads/master.zip",
    destfile = zip_file,
    mode = "wb",
    quiet = FALSE
  )

  unzip(zip_file, exdir = extract_dir)

  package_directory <- file.path(extract_dir, "rSeqTU-master")

  if (!dir.exists(package_directory)) {
    stop(
      "Downloaded rSeqTU source directory was not found: ",
      package_directory,
      call. = FALSE
    )
  }

  r_executable <- file.path(
    R.home("bin"),
    if (.Platform$OS.type == "windows") "R.exe" else "R"
  )

  status <- system2(
    command = r_executable,
    args = c(
      "CMD",
      "INSTALL",
      shQuote(package_directory)
    )
  )

  if (status != 0L || !quiet_require_namespace("rSeqTU")) {
    stop("rSeqTU installation failed.", call. = FALSE)
  }

  invisible(TRUE)
}

check_and_install_packages <- function(install_packages = TRUE) {
  message_section("1. Checking required packages")

  options(repos = c(CRAN = "https://cloud.r-project.org"))

  if (!quiet_require_namespace("BiocManager")) {
    if (!install_packages) {
      stop("BiocManager is not installed.", call. = FALSE)
    }
    install.packages("BiocManager")
  }

  # CRAN packages imported by rSeqTU or needed by this pipeline.
  cran_packages <- c(
    "remotes",
    "e1071",
    "seqinr",
    "gridBase",
    "ggplot2",
    "reshape2",
    "plyr",
    "caret",
    "mlbench",
    "randomForest",
    "kernlab",
    "httr2",
    "dbplyr",
    "data.table",
    "openxlsx"
  )

  # Bioconductor packages imported by rSeqTU or needed by this pipeline.
  bioc_packages <- c(
    "Rsubread",
    "Rsamtools",
    "QuasR",
    "Gviz",
    "GenomicRanges",
    "IRanges",
    "Biostrings",
    "ShortRead",
    "BiocGenerics"
  )

  missing_cran <- cran_packages[
    !vapply(
      cran_packages,
      quiet_require_namespace,
      logical(1)
    )
  ]

  if (length(missing_cran) > 0L) {
    if (!install_packages) {
      stop(
        "Missing CRAN packages: ",
        paste(missing_cran, collapse = ", "),
        call. = FALSE
      )
    }

    install.packages(
      missing_cran,
      dependencies = TRUE,
      type = if (.Platform$OS.type == "windows") "binary" else "source"
    )
  }

  missing_bioc <- bioc_packages[
    !vapply(
      bioc_packages,
      quiet_require_namespace,
      logical(1)
    )
  ]

  if (length(missing_bioc) > 0L) {
    if (!install_packages) {
      stop(
        "Missing Bioconductor packages: ",
        paste(missing_bioc, collapse = ", "),
        call. = FALSE
      )
    }

    BiocManager::install(
      missing_bioc,
      ask = FALSE,
      update = FALSE
    )
  }

  if (!quiet_require_namespace("rSeqTU")) {
    if (!install_packages) {
      stop("rSeqTU is not installed.", call. = FALSE)
    }
    install_rSeqTU()
  }

  required_packages <- unique(
    c(
      cran_packages,
      bioc_packages,
      "BiocManager",
      "rSeqTU"
    )
  )

  status <- package_status(required_packages)
  print(status)

  if (!all(status$installed)) {
    stop(
      "Some required packages remain unavailable: ",
      paste(status$package[!status$installed], collapse = ", "),
      call. = FALSE
    )
  }

  cat("\nrSeqTU version: ")
  print(
    suppressWarnings(
      utils::packageVersion("rSeqTU")
    )
  )

  required_exports <- c(
    "gen_NA",
    "gen_cTU_data",
    "TU_SVM",
    "generate_GTF_training"
  )

  export_check <- required_exports %in% suppressWarnings(
    getNamespaceExports("rSeqTU")
  )

  print(
    data.frame(
      function_name = required_exports,
      exported = export_check,
      row.names = NULL
    )
  )

  if (!all(export_check)) {
    stop("One or more required rSeqTU functions are unavailable.", call. = FALSE)
  }

  invisible(status)
}


# =============================================================================
# 3. BAM PREPARATION: CHECK, SORT WHEN NECESSARY, AND INDEX
# =============================================================================

find_bam_index <- function(bam_file) {
  candidates <- unique(
    c(
      paste0(bam_file, ".bai"),
      sub("\\.[Bb][Aa][Mm]$", ".bai", bam_file)
    )
  )

  existing <- candidates[file.exists(candidates)]

  if (length(existing) == 0L) {
    return(NA_character_)
  }

  normalizePath(existing[1], winslash = "/", mustWork = TRUE)
}

prepare_bam <- function(
  bam_file,
  output_directory,
  overwrite = FALSE
) {
  message_section("2. Preparing and indexing the BAM")

  assert_file(bam_file, "Input BAM")
  assert_directory(output_directory)

  bam_file <- normalizePath(
    bam_file,
    winslash = "/",
    mustWork = TRUE
  )

  index_file <- find_bam_index(bam_file)

  if (!is.na(index_file)) {
    cat("Existing BAM index found:\n", index_file, "\n", sep = "")
    return(
      list(
        bam = bam_file,
        index = index_file
      )
    )
  }

  cat("No BAM index was found. Attempting to index the BAM directly.\n")

  direct_index_ok <- tryCatch(
    {
      Rsamtools::indexBam(bam_file)
      TRUE
    },
    error = function(e) {
      warning(
        "Direct BAM indexing failed: ",
        conditionMessage(e),
        call. = FALSE
      )
      FALSE
    }
  )

  index_file <- find_bam_index(bam_file)

  if (direct_index_ok && !is.na(index_file)) {
    cat("BAM index created:\n", index_file, "\n", sep = "")
    return(
      list(
        bam = bam_file,
        index = index_file
      )
    )
  }

  # If indexing failed, the BAM may not be coordinate sorted.
  input_stem <- tools::file_path_sans_ext(basename(bam_file))
  sorted_prefix <- file.path(
    output_directory,
    paste0(input_stem, ".coordinate_sorted")
  )
  sorted_bam <- paste0(sorted_prefix, ".bam")

  if (!file.exists(sorted_bam) || overwrite) {
    if (overwrite) {
      old_sorted_index <- find_bam_index(sorted_bam)
      if (!is.na(old_sorted_index)) {
        unlink(old_sorted_index)
      }
      if (file.exists(sorted_bam)) {
        unlink(sorted_bam)
      }
    }

    cat(
      "Sorting BAM by genomic coordinate:\n",
      sorted_bam,
      "\n",
      sep = ""
    )

    Rsamtools::sortBam(
      file = bam_file,
      destination = sorted_prefix,
      byQname = FALSE
    )
  } else {
    cat(
      "Using existing coordinate-sorted BAM:\n",
      sorted_bam,
      "\n",
      sep = ""
    )
  }

  assert_file(sorted_bam, "Coordinate-sorted BAM")

  sorted_index <- find_bam_index(sorted_bam)

  if (is.na(sorted_index) || overwrite) {
    Rsamtools::indexBam(sorted_bam)
  }

  sorted_index <- find_bam_index(sorted_bam)

  if (is.na(sorted_index)) {
    stop("Could not create an index for the sorted BAM.", call. = FALSE)
  }

  cat("Coordinate-sorted BAM index:\n", sorted_index, "\n", sep = "")

  list(
    bam = normalizePath(sorted_bam, winslash = "/", mustWork = TRUE),
    index = sorted_index
  )
}

retain_bam_index_in_results <- function(
  bam_file,
  bam_index,
  output_directory
) {
  assert_file(
    bam_file,
    "BAM used for analysis"
  )

  assert_file(
    bam_index,
    "BAM index used for analysis"
  )

  assert_directory(
    output_directory
  )

  source_index <- normalizePath(
    bam_index,
    winslash = "/",
    mustWork = TRUE
  )

  # Use the standard BAM-index naming convention so the copied index clearly
  # corresponds to the BAM used for analysis.
  retained_index <- file.path(
    output_directory,
    paste0(
      basename(bam_file),
      ".bai"
    )
  )

  source_key <- tolower(
    normalizePath(
      source_index,
      winslash = "/",
      mustWork = FALSE
    )
  )

  destination_key <- tolower(
    normalizePath(
      retained_index,
      winslash = "/",
      mustWork = FALSE
    )
  )

  if (!identical(source_key, destination_key)) {
    copied <- file.copy(
      from = source_index,
      to = retained_index,
      overwrite = TRUE,
      copy.mode = TRUE,
      copy.date = TRUE
    )

    if (!isTRUE(copied)) {
      stop(
        "Could not copy the BAM index into the result folder: ",
        retained_index,
        call. = FALSE
      )
    }
  }

  assert_file(
    retained_index,
    "Retained BAM index"
  )

  if (file.info(retained_index)$size <= 0L) {
    stop(
      "The BAM index copied to the result folder is empty: ",
      retained_index,
      call. = FALSE
    )
  }

  cat(
    "BAM index retained in result folder:\n",
    retained_index,
    "\n",
    sep = ""
  )

  normalizePath(
    retained_index,
    winslash = "/",
    mustWork = TRUE
  )
}

copy_file_for_igv <- function(
  source_file,
  destination_file,
  label
) {
  assert_file(
    source_file,
    label
  )

  destination_directory <- dirname(destination_file)

  if (!dir.exists(destination_directory)) {
    created <- dir.create(
      destination_directory,
      recursive = TRUE,
      showWarnings = FALSE
    )

    if (!isTRUE(created) && !dir.exists(destination_directory)) {
      stop(
        "Could not create the IGV destination folder: ",
        destination_directory,
        call. = FALSE
      )
    }
  }

  source_normalized <- normalizePath(
    source_file,
    winslash = "/",
    mustWork = TRUE
  )

  destination_normalized <- normalizePath(
    destination_file,
    winslash = "/",
    mustWork = FALSE
  )

  if (!identical(
    tolower(source_normalized),
    tolower(destination_normalized)
  )) {
    copied <- file.copy(
      from = source_normalized,
      to = destination_file,
      overwrite = TRUE,
      copy.mode = TRUE,
      copy.date = TRUE
    )

    if (!isTRUE(copied)) {
      stop(
        "Could not copy ",
        label,
        " into the IGV Results folder: ",
        destination_file,
        call. = FALSE
      )
    }
  }

  assert_file(
    destination_file,
    paste0("IGV copy of ", label)
  )

  if (file.info(destination_file)$size <= 0L) {
    stop(
      "The IGV copy is empty: ",
      destination_file,
      call. = FALSE
    )
  }

  normalizePath(
    destination_file,
    winslash = "/",
    mustWork = TRUE
  )
}

prepare_igv_result_bundle <- function(
  bam_file,
  bam_index,
  bedgraph_file,
  annotation_file,
  fasta_file,
  igv_directory,
  copy_bam_bai = FALSE
) {
  message_section("11. Preparing the IGV Results folder")

  assert_directory(igv_directory)

  bam_destination <- file.path(
    igv_directory,
    basename(bam_file)
  )

  bai_destination <- file.path(
    igv_directory,
    paste0(
      basename(bam_file),
      ".bai"
    )
  )

  bedgraph_destination <- file.path(
    igv_directory,
    basename(bedgraph_file)
  )

  annotation_destination <- file.path(
    igv_directory,
    basename(annotation_file)
  )

  fasta_destination <- file.path(
    igv_directory,
    basename(fasta_file)
  )

  bam_files <- character(0)

  if (isTRUE(copy_bam_bai)) {
    bam_files <- c(
      BAM = copy_file_for_igv(
        bam_file,
        bam_destination,
        "BAM file"
      ),
      BAI = copy_file_for_igv(
        bam_index,
        bai_destination,
        "BAM index"
      )
    )
  } else {
    # Remove only stale copies for this BAM from an earlier run in the same
    # result folder. The original BAM and BAI are never changed.
    unlink(
      c(bam_destination, bai_destination),
      force = TRUE
    )
    cat(
      "BAM/BAI copy to IGV Results: skipped by user selection.\n",
      sep = ""
    )
  }

  retained_files <- c(
    bam_files,
    bedGraph = copy_file_for_igv(
      bedgraph_file,
      bedgraph_destination,
      "final bedGraph"
    ),
    annotation = copy_file_for_igv(
      annotation_file,
      annotation_destination,
      "input annotation"
    ),
    FASTA = copy_file_for_igv(
      fasta_file,
      fasta_destination,
      "input FASTA"
    )
  )

  bundle_summary <- data.frame(
    result = names(retained_files),
    file = unname(retained_files),
    exists = file.exists(unname(retained_files)),
    size_KB = round(
      file.info(unname(retained_files))$size / 1024,
      2
    ),
    row.names = NULL,
    stringsAsFactors = FALSE
  )

  cat("\nIGV Results folder contents:\n")
  print(bundle_summary)

  if (!all(bundle_summary$exists)) {
    stop(
      "One or more required IGV files were not copied successfully.",
      call. = FALSE
    )
  }

  if (any(file.info(unname(retained_files))$size <= 0L)) {
    stop(
      "One or more files in the IGV Results folder are empty.",
      call. = FALSE
    )
  }

  list(
    directory = normalizePath(
      igv_directory,
      winslash = "/",
      mustWork = TRUE
    ),
    bam = if ("BAM" %in% names(retained_files)) retained_files[["BAM"]] else NULL,
    bai = if ("BAI" %in% names(retained_files)) retained_files[["BAI"]] else NULL,
    bedgraph = retained_files[["bedGraph"]],
    annotation = retained_files[["annotation"]],
    fasta = retained_files[["FASTA"]],
    files = unname(retained_files)
  )
}

get_target_reference <- function(
  bam_file,
  bam_index,
  input_fasta,
  input_gff,
  accession = NULL
) {
  bam_object <- Rsamtools::BamFile(
    file = bam_file,
    index = bam_index
  )

  header_result <- Rsamtools::scanBamHeader(
    bam_object
  )

  extract_targets <- function(x) {
    if (is.null(x)) {
      return(NULL)
    }

    if (
      is.list(x) &&
        !is.null(x$targets)
    ) {
      return(x$targets)
    }

    if (
      is.atomic(x) &&
        is.numeric(x) &&
        !is.null(names(x))
    ) {
      return(x)
    }

    if (is.list(x)) {
      for (element in x) {
        candidate <- extract_targets(element)

        if (!is.null(candidate)) {
          return(candidate)
        }
      }
    }

    NULL
  }

  targets <- extract_targets(header_result)

  if (
    is.null(targets) ||
      length(targets) == 0L
  ) {
    cat(
      "Structure returned by scanBamHeader():\n"
    )
    str(header_result)

    stop(
      "No reference sequences were found in the BAM header.",
      call. = FALSE
    )
  }

  targets <- stats::setNames(
    as.integer(targets),
    names(targets)
  )

  cat("\nReferences found in the BAM:\n")
  print(targets)

  assert_file(
    input_fasta,
    "Input FASTA"
  )

  assert_file(
    input_gff,
    "Input GFF/GFF3"
  )

  fasta_sequences <- Biostrings::readDNAStringSet(
    input_fasta
  )

  if (length(fasta_sequences) == 0L) {
    stop(
      "The FASTA contains no sequences.",
      call. = FALSE
    )
  }

  fasta_names <- names(fasta_sequences)
  fasta_lengths <- as.integer(
    BiocGenerics::width(fasta_sequences)
  )

  raw_gff <- read.delim(
    input_gff,
    sep = "\t",
    header = FALSE,
    comment.char = "#",
    quote = "",
    fill = TRUE,
    stringsAsFactors = FALSE
  )

  if (
    ncol(raw_gff) < 1L ||
      nrow(raw_gff) == 0L
  ) {
    stop(
      "The GFF/GFF3 contains no annotation rows.",
      call. = FALSE
    )
  }

  gff_sequence_ids <- unique(
    trimws(
      as.character(raw_gff[[1]])
    )
  )

  gff_sequence_ids <- gff_sequence_ids[
    !is.na(gff_sequence_ids) &
      nzchar(gff_sequence_ids)
  ]

  if (length(gff_sequence_ids) == 0L) {
    stop(
      "The GFF/GFF3 contains no sequence IDs in column 1.",
      call. = FALSE
    )
  }

  bam_names <- names(targets)

  find_name_matches <- function(
    query,
    candidates
  ) {
    if (
      is.null(query) ||
        is.na(query) ||
        !nzchar(query)
    ) {
      return(integer(0))
    }

    exact <- which(candidates == query)

    if (length(exact) > 0L) {
      return(exact)
    }

    which(
      vapply(
        candidates,
        function(candidate) {
          grepl(
            query,
            candidate,
            fixed = TRUE
          ) ||
            grepl(
              candidate,
              query,
              fixed = TRUE
            )
        },
        logical(1)
      )
    )
  }

  if (
    !is.null(accession) &&
      nzchar(accession)
  ) {
    bam_match <- find_name_matches(
      accession,
      bam_names
    )

    fasta_match <- find_name_matches(
      accession,
      fasta_names
    )

    gff_match <- find_name_matches(
      accession,
      gff_sequence_ids
    )

    if (length(bam_match) != 1L) {
      stop(
        "The chromosome name '",
        accession,
        "' did not uniquely match a BAM reference. ",
        "Available BAM references: ",
        paste(
          bam_names,
          collapse = " | "
        ),
        call. = FALSE
      )
    }

    if (length(fasta_match) != 1L) {
      stop(
        "The chromosome name '",
        accession,
        "' did not uniquely match a FASTA record. ",
        "Available FASTA records: ",
        paste(
          head(fasta_names, 20L),
          collapse = " | "
        ),
        call. = FALSE
      )
    }

    if (length(gff_match) != 1L) {
      stop(
        "The chromosome name '",
        accession,
        "' did not uniquely match a GFF/GFF3 sequence ID. ",
        "Available sequence IDs: ",
        paste(
          head(gff_sequence_ids, 20L),
          collapse = " | "
        ),
        call. = FALSE
      )
    }

    selected_bam_index <- bam_match
    selected_fasta_index <- fasta_match
    selected_gff_id <- gff_sequence_ids[gff_match]
    selection_mode <- "User-specified chromosome"
  } else {
    # Requested GUI behavior:
    # blank chromosome field = first FASTA record and first GFF/GFF3 sequence.
    selected_fasta_index <- 1L
    selected_fasta_name <- fasta_names[1L]
    selected_fasta_token <- sub(
      "\\s.*$",
      "",
      selected_fasta_name
    )
    selected_gff_id <- gff_sequence_ids[1L]

    scores <- numeric(length(targets))

    for (i in seq_along(targets)) {
      bam_name <- bam_names[i]

      scores[i] <-
        1000 * as.integer(
          bam_name == selected_gff_id
        ) +
        800 * as.integer(
          grepl(
            selected_gff_id,
            bam_name,
            fixed = TRUE
          ) ||
            grepl(
              bam_name,
              selected_gff_id,
              fixed = TRUE
            )
        ) +
        700 * as.integer(
          bam_name == selected_fasta_name ||
            bam_name == selected_fasta_token
        ) +
        500 * as.integer(
          grepl(
            selected_fasta_token,
            bam_name,
            fixed = TRUE
          ) ||
            grepl(
              bam_name,
              selected_fasta_token,
              fixed = TRUE
            )
        ) +
        300 * as.integer(
          as.integer(targets[i]) ==
            fasta_lengths[selected_fasta_index]
        )
    }

    if (max(scores) <= 0L) {
      warning(
        "The first FASTA record and first GFF/GFF3 sequence ID did not ",
        "match a BAM reference by name or length. The first BAM reference ",
        "will be used.",
        call. = FALSE
      )

      selected_bam_index <- 1L
    } else {
      best <- which(
        scores == max(scores)
      )

      selected_bam_index <- best[1L]
    }

    selection_mode <- paste0(
      "Automatic: first FASTA record ('",
      selected_fasta_name,
      "') and first GFF/GFF3 sequence ID ('",
      selected_gff_id,
      "')"
    )
  }

  target_name <- bam_names[selected_bam_index]
  target_length <- as.integer(
    targets[selected_bam_index]
  )

  fasta_record_name <- fasta_names[
    selected_fasta_index
  ]

  fasta_record_length <- fasta_lengths[
    selected_fasta_index
  ]

  if (
    as.integer(fasta_record_length) !=
      as.integer(target_length)
  ) {
    stop(
      "The selected FASTA record length (",
      fasta_record_length,
      ") does not equal the selected BAM reference length (",
      target_length,
      "). Selected FASTA record: ",
      fasta_record_name,
      "; selected BAM reference: ",
      target_name,
      ".",
      call. = FALSE
    )
  }

  output_accession <- if (
    !is.null(accession) &&
      nzchar(accession)
  ) {
    accession
  } else {
    selected_gff_id
  }

  cat("\nChromosome selection mode:\n")
  cat(selection_mode, "\n")

  cat("\nSelected BAM reference:\n")
  print(target_name)

  cat(
    "Selected FASTA record: ",
    fasta_record_name,
    "\n",
    sep = ""
  )

  cat(
    "Selected GFF/GFF3 sequence ID: ",
    selected_gff_id,
    "\n",
    sep = ""
  )

  cat(
    "Reference length: ",
    target_length,
    "\n",
    sep = ""
  )

  list(
    name = target_name,
    length = target_length,
    accession = output_accession,
    fasta_record_name = fasta_record_name,
    gff_sequence_id = selected_gff_id
  )
}


# =============================================================================
# 3B. QUASR QUALITY-CONTROL REPORT
# =============================================================================

run_QuasR_QC <- function(
  bam_file,
  output_directory,
  output_prefix,
  chunk_size = 1000000L,
  overwrite = FALSE
) {
  message_section("2B. Generating QuasR BAM quality-control report")

  assert_file(bam_file, "BAM for QuasR QC")
  assert_directory(output_directory)

  bam_index <- find_bam_index(bam_file)

  if (is.na(bam_index)) {
    stop(
      "QuasR QC requires an indexed BAM. No BAM index was found for: ",
      bam_file,
      call. = FALSE
    )
  }

  qc_pdf <- file.path(
    output_directory,
    paste0(output_prefix, " QuasR QC report.pdf")
  )

  if (!file.exists(qc_pdf) || overwrite) {
    QuasR::qQCReport(
      input = bam_file,
      pdfFilename = qc_pdf,
      chunkSize = as.integer(chunk_size),
      useSampleNames = FALSE
    )
  } else {
    cat("Existing QuasR QC PDF retained:\n", qc_pdf, "\n", sep = "")
  }

  if (!file.exists(qc_pdf) || file.info(qc_pdf)$size <= 0L) {
    stop(
      "The QuasR QC report was not created correctly: ",
      qc_pdf,
      call. = FALSE
    )
  }

  print(
    data.frame(
      file = basename(qc_pdf),
      exists = file.exists(qc_pdf),
      size_KB = round(file.info(qc_pdf)$size / 1024, 2),
      row.names = NULL
    )
  )

  invisible(
    list(
      qc_pdf = qc_pdf
    )
  )
}


# =============================================================================
# 4. FIXED BAM-TO-.NA FUNCTION FOR A MULTI-REFERENCE BAM
# =============================================================================

# The package's original gen_NA() uses all values returned by seqlengths(bf)
# where one scalar length is expected. That fails or warns for a BAM containing
# multiple reference sequences. This function explicitly selects one reference.

generate_selected_reference_NA <- function(
  bam_file,
  bam_index,
  reference_name,
  reference_length,
  output_file,
  min_mapq = 15L,
  min_base_quality = 10L,
  swap_strands = FALSE,
  overwrite = FALSE
) {
  message_section("3. Generating chromosome-specific .NA coverage")

  if (file.exists(output_file) && !overwrite) {
    cat(
      "Existing .NA file retained:\n",
      output_file,
      "\n",
      sep = ""
    )
    return(normalizePath(output_file, winslash = "/", mustWork = TRUE))
  }

  output_parent <- dirname(output_file)
  assert_directory(output_parent)

  bam_object <- Rsamtools::BamFile(
    file = bam_file,
    index = bam_index
  )

  selected_range <- GenomicRanges::GRanges(
    seqnames = reference_name,
    ranges = IRanges::IRanges(
      start = 1L,
      end = reference_length
    )
  )

  scan_parameter <- Rsamtools::ScanBamParam(
    which = selected_range
  )

  pileup_parameter <- Rsamtools::PileupParam(
    min_mapq = min_mapq,
    min_base_quality = min_base_quality,
    distinguish_strands = TRUE,
    distinguish_nucleotides = TRUE
  )

  cat("Running pileup for selected reference only ...\n")

  pileup_result <- Rsamtools::pileup(
    bam_object,
    scanBamParam = scan_parameter,
    pileupParam = pileup_parameter
  )

  forward_coverage <- numeric(reference_length)
  reverse_coverage <- numeric(reference_length)

  if (nrow(pileup_result) > 0L) {
    pileup_table <- data.table::as.data.table(pileup_result)

    aggregate_coverage <- pileup_table[
      ,
      list(coverage = sum(count)),
      by = list(pos, strand)
    ]

    forward_rows <- aggregate_coverage$strand == "+"
    reverse_rows <- aggregate_coverage$strand == "-"

    forward_positions <- as.integer(
      aggregate_coverage$pos[forward_rows]
    )
    reverse_positions <- as.integer(
      aggregate_coverage$pos[reverse_rows]
    )

    forward_coverage[forward_positions] <-
      aggregate_coverage$coverage[forward_rows]

    reverse_coverage[reverse_positions] <-
      aggregate_coverage$coverage[reverse_rows]
  }

  forward_coverage[!is.finite(forward_coverage)] <- 0
  reverse_coverage[!is.finite(reverse_coverage)] <- 0

  if (swap_strands) {
    temporary <- forward_coverage
    forward_coverage <- reverse_coverage
    reverse_coverage <- temporary
  }

  coverage_output <- data.table::data.table(
    forward = forward_coverage,
    reverse = reverse_coverage
  )

  data.table::fwrite(
    coverage_output,
    file = output_file,
    sep = "\t",
    col.names = FALSE,
    quote = FALSE
  )

  if (!file.exists(output_file)) {
    stop(".NA output was not created.", call. = FALSE)
  }

  cat("Created: ", output_file, "\n", sep = "")
  cat("Output rows: ", nrow(coverage_output), "\n", sep = "")
  cat("Output columns: ", ncol(coverage_output), "\n", sep = "")

  normalizePath(output_file, winslash = "/", mustWork = TRUE)
}

validate_NA_file <- function(
  na_file,
  reference_length
) {
  message_section("4. Validating the .NA file")

  assert_file(na_file, ".NA file")

  coverage <- data.table::fread(
    na_file,
    header = FALSE,
    sep = "\t",
    data.table = FALSE,
    showProgress = FALSE
  )

  if (ncol(coverage) != 2L) {
    stop(
      "The .NA file must contain exactly two columns; found ",
      ncol(coverage),
      ".",
      call. = FALSE
    )
  }

  if (nrow(coverage) != reference_length) {
    stop(
      "The .NA file contains ",
      nrow(coverage),
      " rows, but the selected chromosome is ",
      reference_length,
      " bp.",
      call. = FALSE
    )
  }

  non_finite <- sum(!is.finite(as.matrix(coverage)))

  if (non_finite != 0L) {
    stop(
      "The .NA file contains ",
      non_finite,
      " missing or non-finite values.",
      call. = FALSE
    )
  }

  cat("Coverage dimensions:\n")
  print(dim(coverage))

  cat("Missing values: ", sum(is.na(coverage)), "\n", sep = "")
  cat("Non-finite values: ", non_finite, "\n", sep = "")

  rm(coverage)
  invisible(gc())

  TRUE
}


# =============================================================================
# 5. PREPARE THE COMPLETE CHROMOSOME FASTA
# =============================================================================

prepare_chromosome_fasta <- function(
  input_fasta,
  accession,
  fasta_record_name,
  expected_length,
  output_fasta,
  output_sequence_name,
  overwrite = FALSE
) {
  message_section("5. Preparing and validating chromosome FASTA")

  assert_file(input_fasta, "Input FASTA")

  sequences <- Biostrings::readDNAStringSet(input_fasta)

  cat("Number of FASTA records: ", length(sequences), "\n", sep = "")

  matching_index <- which(
    names(sequences) == fasta_record_name
  )

  if (length(matching_index) == 0L) {
    matching_index <- grep(
      fasta_record_name,
      names(sequences),
      fixed = TRUE
    )
  }

  # Accept a one-record FASTA with the exact expected length even when the
  # header changed after preprocessing.
  if (
    length(matching_index) == 0L &&
    length(sequences) == 1L &&
    as.integer(BiocGenerics::width(sequences)[1]) == expected_length
  ) {
    matching_index <- 1L
  }

  if (length(matching_index) != 1L) {
    displayed_names <- head(names(sequences), 20L)

    stop(
      "Could not uniquely find the complete chromosome ",
      accession,
      ". The selected FASTA appears to contain ",
      length(sequences),
      " records. First entries: ",
      paste(displayed_names, collapse = " | "),
      "\nUse a complete genomic FASTA, not a CDS or RNA FASTA.",
      call. = FALSE
    )
  }

  chromosome <- sequences[matching_index]
  chromosome_length <- as.integer(BiocGenerics::width(chromosome)[1])

  cat("Selected FASTA record:\n")
  print(names(chromosome))
  cat("Selected length: ", chromosome_length, "\n", sep = "")

  if (chromosome_length != expected_length) {
    stop(
      "FASTA length ",
      chromosome_length,
      " does not equal BAM reference length ",
      expected_length,
      ".",
      call. = FALSE
    )
  }

  # Use the BAM sequence name so BAM, GFF, BED and FASTA agree.
  names(chromosome) <- output_sequence_name

  if (!file.exists(output_fasta) || overwrite) {
    Biostrings::writeXStringSet(
      chromosome,
      filepath = output_fasta,
      format = "fasta"
    )
  }

  output_check <- Biostrings::readDNAStringSet(output_fasta)

  if (
    length(output_check) != 1L ||
    as.integer(BiocGenerics::width(output_check)[1]) != expected_length
  ) {
    stop("Chromosome-only FASTA validation failed.", call. = FALSE)
  }

  cat("Chromosome-only FASTA:\n", output_fasta, "\n", sep = "")

  normalizePath(output_fasta, winslash = "/", mustWork = TRUE)
}


# =============================================================================
# 6. PREPARE AN rSeqTU-COMPATIBLE GFF
# =============================================================================

extract_gff_attribute <- function(attributes, key) {
  attributes <- as.character(attributes)

  extract_one <- function(value) {
    if (is.na(value) || !nzchar(value)) {
      return(NA_character_)
    }

    patterns <- c(
      paste0("(?:^|;)\\s*", key, "=([^;]+)"),
      paste0("(?:^|;)\\s*", key, "\\s+\"([^\"]+)\"")
    )

    for (pattern in patterns) {
      match_object <- regexec(
        pattern,
        value,
        perl = TRUE,
        ignore.case = FALSE
      )

      match_value <- regmatches(value, match_object)[[1]]

      if (length(match_value) >= 2L) {
        return(trimws(match_value[2]))
      }
    }

    NA_character_
  }

  vapply(attributes, extract_one, character(1))
}

select_best_gene_identifier <- function(attributes, make_unique = TRUE) {
  keys <- c(
    "locus_tag",
    "Name",
    "gene",
    "gene_id",
    "ID",
    "Parent"
  )

  identifiers <- rep(NA_character_, length(attributes))

  for (key in keys) {
    candidate <- extract_gff_attribute(attributes, key)
    missing <- is.na(identifiers) | identifiers == ""
    identifiers[missing] <- candidate[missing]
  }

  missing <- is.na(identifiers) | identifiers == ""

  identifiers[missing] <- sprintf(
    "gene_%05d",
    which(missing)
  )

  identifiers <- sub("^gene-", "", identifiers)
  identifiers <- gsub("[^A-Za-z0-9_.-]", "_", identifiers)

  if (make_unique) {
    identifiers <- make.unique(identifiers, sep = "_")
  }

  identifiers
}

prepare_rSeqTU_gff <- function(
  input_gff,
  accession,
  gff_sequence_id,
  bam_reference_name,
  genome_length,
  output_gff,
  overwrite = FALSE
) {
  message_section("6. Preparing rSeqTU-compatible chromosome GFF")

  assert_file(input_gff, "Input GFF")

  raw_gff <- read.delim(
    input_gff,
    sep = "\t",
    header = FALSE,
    comment.char = "#",
    quote = "",
    fill = TRUE,
    stringsAsFactors = FALSE
  )

  if (ncol(raw_gff) < 9L) {
    stop("The annotation does not contain nine GFF columns.", call. = FALSE)
  }

  raw_gff <- raw_gff[, 1:9]
  colnames(raw_gff) <- paste0("V", 1:9)

  raw_gff$V4 <- suppressWarnings(as.integer(raw_gff$V4))
  raw_gff$V5 <- suppressWarnings(as.integer(raw_gff$V5))

  raw_gff <- raw_gff[
    !is.na(raw_gff$V1) &
      !is.na(raw_gff$V3) &
      !is.na(raw_gff$V4) &
      !is.na(raw_gff$V5),
    ,
    drop = FALSE
  ]

  sequence_candidates <- unique(
    raw_gff$V1[
      raw_gff$V1 == gff_sequence_id
    ]
  )

  if (length(sequence_candidates) == 0L) {
    sequence_candidates <- unique(
      raw_gff$V1[
        grepl(
          gff_sequence_id,
          raw_gff$V1,
          fixed = TRUE
        )
      ]
    )
  }

  if (length(sequence_candidates) != 1L) {
    stop(
      "The selected GFF/GFF3 sequence ID '",
      gff_sequence_id,
      "' was not found uniquely in column 1. Available sequence names: ",
      paste(
        head(
          unique(raw_gff$V1),
          20L
        ),
        collapse = " | "
      ),
      call. = FALSE
    )
  }

  selected_annotation <- raw_gff[
    raw_gff$V1 == sequence_candidates[1L],
    ,
    drop = FALSE
  ]

  gene_rows <- selected_annotation[
    tolower(selected_annotation$V3) == "gene",
    ,
    drop = FALSE
  ]

  cat("Existing gene rows selected: ", nrow(gene_rows), "\n", sep = "")

  if (nrow(gene_rows) > 0L) {
    gene_ids <- select_best_gene_identifier(gene_rows$V9)

    compatible_gff <- data.frame(
      V1 = bam_reference_name,
      V2 = "rSeqTU",
      V3 = "gene",
      V4 = gene_rows$V4,
      V5 = gene_rows$V5,
      V6 = ".",
      V7 = gene_rows$V7,
      V8 = ".",
      V9 = paste0(
        "ID=",
        gene_ids,
        ";locus_tag=",
        gene_ids
      ),
      stringsAsFactors = FALSE
    )
  } else {
    message(
      "No gene features were found. Constructing gene rows from CDS features."
    )

    cds_rows <- selected_annotation[
      tolower(selected_annotation$V3) == "cds",
      ,
      drop = FALSE
    ]

    if (nrow(cds_rows) == 0L) {
      stop(
        "The selected chromosome annotation contains neither gene nor CDS rows.",
        call. = FALSE
      )
    }

    cds_ids <- select_best_gene_identifier(
      cds_rows$V9,
      make_unique = FALSE
    )
    groups <- split(seq_len(nrow(cds_rows)), cds_ids)

    compatible_gff <- do.call(
      rbind,
      lapply(
        names(groups),
        function(gene_id) {
          rows <- cds_rows[groups[[gene_id]], , drop = FALSE]

          data.frame(
            V1 = bam_reference_name,
            V2 = "rSeqTU",
            V3 = "gene",
            V4 = min(rows$V4),
            V5 = max(rows$V5),
            V6 = ".",
            V7 = rows$V7[1],
            V8 = ".",
            V9 = paste0(
              "ID=",
              gene_id,
              ";locus_tag=",
              gene_id
            ),
            stringsAsFactors = FALSE
          )
        }
      )
    )
  }

  compatible_gff$V4 <- as.integer(compatible_gff$V4)
  compatible_gff$V5 <- as.integer(compatible_gff$V5)

  invalid <- (
    is.na(compatible_gff$V4) |
      is.na(compatible_gff$V5) |
      compatible_gff$V4 < 1L |
      compatible_gff$V5 < compatible_gff$V4 |
      compatible_gff$V5 > genome_length |
      !compatible_gff$V7 %in% c("+", "-")
  )

  cat("Rows incompatible with the linear rSeqTU model: ",
      sum(invalid), "\n", sep = "")

  if (any(invalid)) {
    cat(
      "\nRows removed, including any circular origin-spanning gene:\n"
    )
    print(
      compatible_gff[
        invalid,
        c("V1", "V3", "V4", "V5", "V7", "V9"),
        drop = FALSE
      ]
    )
  }

  compatible_gff <- compatible_gff[
    !invalid,
    ,
    drop = FALSE
  ]

  compatible_gff <- compatible_gff[
    order(compatible_gff$V4, compatible_gff$V5),
    ,
    drop = FALSE
  ]

  if (nrow(compatible_gff) < 2L) {
    stop("Too few valid genes remain for TU prediction.", call. = FALSE)
  }

  if (!all(grepl("locus_tag=", compatible_gff$V9, fixed = TRUE))) {
    stop("Some GFF rows still lack locus_tag.", call. = FALSE)
  }

  if (!file.exists(output_gff) || overwrite) {
    write.table(
      compatible_gff,
      file = output_gff,
      sep = "\t",
      quote = FALSE,
      row.names = FALSE,
      col.names = FALSE
    )
  }

  cat("Clean GFF created:\n", output_gff, "\n", sep = "")
  cat("Remaining gene rows: ", nrow(compatible_gff), "\n", sep = "")
  cat("Forward genes: ",
      sum(compatible_gff$V7 == "+"), "\n", sep = "")
  cat("Reverse genes: ",
      sum(compatible_gff$V7 == "-"), "\n", sep = "")
  cat("Maximum coordinate: ",
      max(compatible_gff$V5), "\n", sep = "")

  list(
    file = normalizePath(output_gff, winslash = "/", mustWork = TRUE),
    data = compatible_gff
  )
}

create_SVM_gff_with_seven_headers <- function(
  clean_gff,
  svm_gff
) {
  message_section("7. Creating the seven-header GFF required by TU_SVM")

  gff_content <- readLines(clean_gff, warn = FALSE)

  writeLines(
    c(
      "##gff-version 3",
      "##rSeqTU-header-2",
      "##rSeqTU-header-3",
      "##rSeqTU-header-4",
      "##rSeqTU-header-5",
      "##rSeqTU-header-6",
      "##rSeqTU-header-7",
      gff_content
    ),
    svm_gff
  )

  test_gff <- read.delim(
    svm_gff,
    skip = 7,
    header = FALSE,
    sep = "\t",
    quote = "",
    stringsAsFactors = FALSE
  )

  if (ncol(test_gff) < 9L || !all(test_gff$V3 == "gene")) {
    stop("The seven-header SVM GFF was not created correctly.", call. = FALSE)
  }

  cat("SVM GFF created:\n", svm_gff, "\n", sep = "")
  cat("Gene rows after skip = 7: ", nrow(test_gff), "\n", sep = "")

  normalizePath(svm_gff, winslash = "/", mustWork = TRUE)
}


# =============================================================================
# 7. rSeqTU FEATURE GENERATION
# =============================================================================

run_gen_cTU_data <- function(
  na_file,
  file_prefix,
  clean_gff,
  chromosome_fasta,
  output_directory,
  overwrite = FALSE
) {
  message_section("8. Running rSeqTU::gen_cTU_data")

  # rSeqTU prepends text to fileNamePrefix. It must therefore be a simple
  # basename, not a Windows path containing E:/ or another drive prefix.
  if (grepl("[/\\\\:]", file_prefix)) {
    stop(
      "fileNamePrefix must not contain a path, slash, backslash, or colon.",
      call. = FALSE
    )
  }

  expected_files <- file.path(
    output_directory,
    c(
      paste0("SVM.TwoStrands.Training.", file_prefix),
      paste0("SVM.TwoStrands.Target.", file_prefix),
      "TargetPositiveTUMatrix.txt",
      "TargetNegativeTUMatrix.txt",
      "SimulatedPositiveTUMatrix.txt",
      "SimulatedNegativeTUMatrix.txt"
    )
  )

  if (all(file.exists(expected_files)) && !overwrite) {
    cat("All feature files already exist. Feature generation was skipped.\n")
  } else {
    use_working_directory(
      output_directory,
      rSeqTU::gen_cTU_data(
        file_RNAseqSignals = na_file,
        fileNamePrefix = file_prefix,
        file_gff = clean_gff,
        genomeFile = chromosome_fasta
      )
    )
  }

  result <- data.frame(
    file = basename(expected_files),
    exists = file.exists(expected_files),
    size_MB = safe_file_size(expected_files),
    row.names = NULL
  )

  print(result)

  if (!all(result$exists)) {
    stop("One or more gen_cTU_data output files are missing.", call. = FALSE)
  }

  invisible(expected_files)
}


# =============================================================================
# 8. RUN TU_SVM
# =============================================================================

run_TU_SVM <- function(
  na_file,
  svm_gff,
  output_prefix,
  genome_name,
  output_directory,
  seed = 123L,
  overwrite = FALSE
) {
  message_section("9. Running rSeqTU::TU_SVM")

  final_table <- file.path(
    output_directory,
    paste0(output_prefix, "_FinalTUTable_forPlot")
  )

  package_bedgraph <- file.path(
    output_directory,
    paste0(output_prefix, "_result.bedgraph")
  )

  if (
    file.exists(final_table) &&
    file.exists(package_bedgraph) &&
    !overwrite
  ) {
    cat("Final SVM outputs already exist. TU_SVM was skipped.\n")
    return(
      list(
        table = final_table,
        bedgraph = package_bedgraph
      )
    )
  }

  model_packages <- c(
    "caret",
    "randomForest",
    "kernlab",
    "class"
  )

  model_status <- package_status(model_packages)
  print(model_status)

  if (!all(model_status$installed)) {
    stop(
      "Missing modelling packages: ",
      paste(
        model_status$package[!model_status$installed],
        collapse = ", "
      ),
      call. = FALSE
    )
  }

  set.seed(seed)

  # TU_SVM currently ignores the four matrix paths and reads fixed filenames
  # from the working directory, so the working directory must be OUTPUT_DIR.
  #
  # The legacy package also calls Unix commands `sed` and `mv` after writing
  # the final table. Those commands are absent on standard Windows systems.
  # This pipeline performs the same cleanup safely in R immediately afterward,
  # so only those two known warnings are muffled. Any other warning remains
  # visible and is not hidden.
  legacy_warning_handler <- function(warning_condition) {
    warning_text <- conditionMessage(
      warning_condition
    )

    known_legacy_warning <- grepl(
      "'sed' not found|'mv' not found",
      warning_text
    )

    known_namespace_warning <- grepl(
      "^replacing previous import ",
      warning_text
    )

    if (
      known_legacy_warning ||
        known_namespace_warning
    ) {
      invokeRestart("muffleWarning")
    }
  }

  use_working_directory(
    output_directory,
    suppressPackageStartupMessages(
      withCallingHandlers(
        rSeqTU::TU_SVM(
          positive_training = "SimulatedPositiveTUMatrix.txt",
          negative_training = "SimulatedNegativeTUMatrix.txt",
          positive_strand_testing = "TargetPositiveTUMatrix.txt",
          negative_strand_testing = "TargetNegativeTUMatrix.txt",
          file_RNAseqSignals = na_file,
          file_gff = basename(svm_gff),
          output_prefix = output_prefix,
          genome_name = genome_name
        ),
        warning = legacy_warning_handler
      )
    )
  )

  if (!file.exists(final_table) || !file.exists(package_bedgraph)) {
    stop("TU_SVM did not create both final output files.", call. = FALSE)
  }

  cat(
    "Legacy Windows sed/mv cleanup is handled internally by R.\n"
  )

  list(
    table = final_table,
    bedgraph = package_bedgraph
  )
}


# =============================================================================
# 9. FINAL OUTPUT: ONE PLOT FILE AND ONE STRAND-AWARE BEDGRAPH
# =============================================================================

postprocess_TU_results <- function(
  final_table_file,
  chromosome_name,
  internal_prefix,
  display_prefix,
  output_directory,
  igv_directory
) {
  message_section(
    "10. Finalizing the TU Excel workbook and strand-aware bedGraph"
  )

  if (!file.exists(final_table_file)) {
    stop(
      "The rSeqTU final plot table does not exist: ",
      final_table_file,
      call. = FALSE
    )
  }

  # rSeqTU writes five result columns plus TU IDs as row names:
  # TU_ID, Start, End, Strand, Confidence, Genes.
  # On Windows, its sed/mv cleanup may fail, so clean the file entirely in R.
  tu <- read.delim(
    final_table_file,
    header = FALSE,
    sep = "	",
    quote = "\"",
    comment.char = "",
    fill = TRUE,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  # Remove completely empty columns, if any.
  keep_column <- vapply(
    tu,
    function(x) any(!is.na(x) & trimws(as.character(x)) != ""),
    logical(1)
  )
  tu <- tu[, keep_column, drop = FALSE]

  if (ncol(tu) != 6L) {
    stop(
      "Unexpected rSeqTU plot-table structure. Expected 6 columns ",
      "(TU_ID, Start, End, Strand, Confidence, Genes), but found ",
      ncol(tu),
      ".",
      call. = FALSE
    )
  }

  colnames(tu) <- c(
    "TU_ID",
    "Start",
    "End",
    "Strand",
    "Confidence",
    "Genes"
  )

  tu$TU_ID <- trimws(as.character(tu$TU_ID))
  tu$Start <- suppressWarnings(as.integer(tu$Start))
  tu$End <- suppressWarnings(as.integer(tu$End))
  tu$Strand <- trimws(as.character(tu$Strand))
  tu$Confidence <- suppressWarnings(as.numeric(tu$Confidence))
  tu$Genes <- trimws(as.character(tu$Genes))

  invalid <- (
    is.na(tu$TU_ID) |
      tu$TU_ID == "" |
      is.na(tu$Start) |
      is.na(tu$End) |
      tu$Start < 1L |
      tu$End < tu$Start |
      !tu$Strand %in% c("+", "-")
  )

  if (any(invalid)) {
    cat("\nInvalid rows detected in the rSeqTU plot table:\n")
    print(tu[invalid, , drop = FALSE])

    stop(
      "The final plot table contains invalid coordinates or strand values.",
      call. = FALSE
    )
  }

  tu <- tu[order(tu$Start, tu$End, tu$Strand), , drop = FALSE]
  rownames(tu) <- NULL

  strand_count <- table(
    factor(tu$Strand, levels = c("+", "-"))
  )

  cat("\nPredicted transcription units by strand:\n")
  print(strand_count)

  if (strand_count["+"] == 0L) {
    stop(
      "No forward-strand transcription units were found in the rSeqTU result.",
      call. = FALSE
    )
  }

  if (strand_count["-"] == 0L) {
    stop(
      "No reverse-strand transcription units were found in the rSeqTU result. ",
      "The bedGraph was not written because the upstream result lacks reverse TUs.",
      call. = FALSE
    )
  }

  # Export the final TU table as a formatted Excel workbook.
  excel_file <- file.path(
    output_directory,
    paste0(
      display_prefix,
      " Final TU Table.xlsx"
    )
  )

  workbook <- openxlsx::createWorkbook(
    creator = "rSeqTU Transcription Unit Predictor"
  )

  openxlsx::addWorksheet(
    workbook,
    "Transcription Units",
    gridLines = FALSE
  )

  tu_export <- tu
  colnames(tu_export) <- c(
    "TU ID",
    "Start",
    "End",
    "Strand",
    "Confidence",
    "Genes"
  )

  title_style <- openxlsx::createStyle(
    fontName = "Arial",
    fontSize = 14,
    textDecoration = "bold",
    fontColour = "#000000",
    halign = "left",
    valign = "center",
    border = "Bottom",
    borderColour = "#000000"
  )

  header_style <- openxlsx::createStyle(
    fontName = "Arial",
    fontSize = 11,
    textDecoration = "bold",
    fontColour = "#000000",
    fgFill = "#FFFFFF",
    halign = "center",
    valign = "center",
    border = "TopBottomLeftRight",
    borderColour = "#DCE5DF"
  )

  body_style <- openxlsx::createStyle(
    fontName = "Arial",
    fontSize = 10,
    fontColour = "#000000",
    fgFill = "#FFFFFF",
    valign = "center",
    border = "TopBottomLeftRight",
    borderColour = "#DCE5DF"
  )

  integer_style <- openxlsx::createStyle(
    numFmt = "0",
    halign = "right",
    border = "TopBottomLeftRight",
    borderColour = "#DCE5DF"
  )

  confidence_style <- openxlsx::createStyle(
    numFmt = "0.0000",
    halign = "right",
    border = "TopBottomLeftRight",
    borderColour = "#DCE5DF"
  )

  openxlsx::writeData(
    workbook,
    "Transcription Units",
    paste0(
      display_prefix,
      " - Predicted Transcription Units"
    ),
    startRow = 1L,
    startCol = 1L
  )

  openxlsx::mergeCells(
    workbook,
    "Transcription Units",
    cols = 1:6,
    rows = 1L
  )

  openxlsx::addStyle(
    workbook,
    "Transcription Units",
    title_style,
    rows = 1L,
    cols = 1:6,
    gridExpand = TRUE
  )

  openxlsx::setRowHeights(
    workbook,
    "Transcription Units",
    rows = 1L,
    heights = 25
  )

  # Write the column headers directly below the title. There is intentionally
  # no blank second row. Rows use a plain white fill and visible cell borders.
  openxlsx::writeData(
    workbook,
    "Transcription Units",
    tu_export,
    startRow = 2L,
    startCol = 1L,
    colNames = TRUE,
    rowNames = FALSE,
    withFilter = TRUE
  )

  openxlsx::addStyle(
    workbook,
    "Transcription Units",
    header_style,
    rows = 2L,
    cols = 1:6,
    gridExpand = TRUE,
    stack = TRUE
  )

  if (nrow(tu_export) > 0L) {
    data_rows <- 3L:(nrow(tu_export) + 2L)

    openxlsx::addStyle(
      workbook,
      "Transcription Units",
      body_style,
      rows = data_rows,
      cols = 1:6,
      gridExpand = TRUE,
      stack = TRUE
    )

    openxlsx::addStyle(
      workbook,
      "Transcription Units",
      integer_style,
      rows = data_rows,
      cols = 2:3,
      gridExpand = TRUE,
      stack = TRUE
    )

    openxlsx::addStyle(
      workbook,
      "Transcription Units",
      confidence_style,
      rows = data_rows,
      cols = 5L,
      gridExpand = TRUE,
      stack = TRUE
    )
  }

  openxlsx::freezePane(
    workbook,
    "Transcription Units",
    firstActiveRow = 3L
  )

  openxlsx::setColWidths(
    workbook,
    "Transcription Units",
    cols = 1:6,
    widths = c(15, 13, 13, 10, 14, 45)
  )

  openxlsx::saveWorkbook(
    workbook,
    excel_file,
    overwrite = TRUE
  )

  if (
    !file.exists(excel_file) ||
      file.info(excel_file)$size <= 0L
  ) {
    stop(
      "The final TU Excel workbook was not created correctly: ",
      excel_file,
      call. = FALSE
    )
  }

  # The package-generated extensionless plot file is an intermediate once the
  # Excel workbook has been verified.
  if (file.exists(final_table_file)) {
    unlink(
      final_table_file,
      force = TRUE
    )
  }

  # Confidence magnitude:
  # - use the rSeqTU confidence when it is finite and between 0 and 1;
  # - otherwise use 1.
  confidence_magnitude <- tu$Confidence
  confidence_magnitude[
    !is.finite(confidence_magnitude) |
      confidence_magnitude <= 0
  ] <- 1

  confidence_magnitude <- pmin(
    pmax(confidence_magnitude, 0),
    1
  )

  # bedGraph convention:
  #   forward strand = positive value, plotted above zero
  #   reverse strand = negative value, plotted below zero
  # bedGraph coordinates are 0-based and half-open.
  bedgraph_data <- data.frame(
    chrom = rep(chromosome_name, nrow(tu)),
    chromStart = pmax(tu$Start - 1L, 0L),
    chromEnd = tu$End,
    value = ifelse(
      tu$Strand == "+",
      confidence_magnitude,
      -confidence_magnitude
    ),
    stringsAsFactors = FALSE
  )

  assert_directory(igv_directory)

  bedgraph_file <- file.path(
    igv_directory,
    paste0(
      display_prefix,
      " result.bedgraph"
    )
  )

  track_name <- gsub(
    "[^A-Za-z0-9_.-]",
    "_",
    paste0(display_prefix, " predicted TUs")
  )

  writeLines(
    paste0(
      'track type=bedGraph name="',
      track_name,
      '" description="Forward positive; reverse negative" ',
      'color=0,128,0 altColor=200,0,0 alwaysZero=on viewLimits=-1:1'
    ),
    con = bedgraph_file
  )

  write.table(
    bedgraph_data,
    file = bedgraph_file,
    sep = "	",
    quote = FALSE,
    row.names = FALSE,
    col.names = FALSE,
    append = TRUE
  )

  # Remove older alternative final files so only the two canonical TU outputs
  # remain and there is no ambiguity about which file to load.
  obsolete_final_files <- file.path(
    output_directory,
    c(
      # Raw package output. The final space-named bedGraph below is the only
      # bedGraph retained for users.
      paste0(internal_prefix, "_result.bedgraph"),
      paste0(internal_prefix, "_FinalTUTable_labelled.tsv"),
      paste0(internal_prefix, "_predicted_TUs.bed"),
      paste0(internal_prefix, "_result_corrected.bedgraph")
    )
  )

  files_to_remove <- obsolete_final_files[
    file.exists(obsolete_final_files)
  ]

  if (length(files_to_remove) > 0L) {
    unlink(
      files_to_remove,
      force = TRUE
    )

    cat(
      "\nRemoved package-generated alternative files so only the final ",
      "Excel workbook and final space-named bedGraph remain:\n",
      paste(basename(files_to_remove), collapse = "\n"),
      "\n",
      sep = ""
    )
  }

  # Verify that signs in the bedGraph exactly match plot-table strands.
  negative_count <- sum(bedgraph_data$value < 0)
  positive_count <- sum(bedgraph_data$value > 0)

  if (positive_count != unname(strand_count["+"])) {
    stop(
      "Forward-strand verification failed while writing the bedGraph.",
      call. = FALSE
    )
  }

  if (negative_count != unname(strand_count["-"])) {
    stop(
      "Reverse-strand verification failed while writing the bedGraph.",
      call. = FALSE
    )
  }

  output_files <- c(
    excel_file,
    bedgraph_file
  )

  result <- data.frame(
    file = basename(output_files),
    exists = file.exists(output_files),
    size_KB = round(file.info(output_files)$size / 1024, 2),
    row.names = NULL
  )

  cat("\nFinal TU files:\n")
  print(result)

  cat(
    "\nForward TUs in bedGraph: ",
    positive_count,
    "\n",
    sep = ""
  )

  cat(
    "Reverse TUs in bedGraph: ",
    negative_count,
    "\n",
    sep = ""
  )

  if (!all(result$exists)) {
    stop(
      "The final TU Excel workbook or bedGraph is missing.",
      call. = FALSE
    )
  }

  invisible(
    list(
      plot_file = excel_file,
      bedgraph_file = bedgraph_file,
      forward_TUs = positive_count,
      reverse_TUs = negative_count,
      data = tu
    )
  )
}


# =============================================================================
# 10. DELETE GENERATED INTERMEDIATE FILES
# =============================================================================

delete_generated_intermediates <- function(
  input_bam,
  input_bam_index_before,
  bam_used,
  bam_index_used,
  na_file,
  chromosome_fasta,
  clean_gff,
  svm_gff,
  output_prefix,
  output_directory,
  final_files
) {
  message_section("12. Deleting generated intermediate files")

  normalize_optional <- function(path) {
    if (length(path) == 0L || is.na(path) || !nzchar(path)) {
      return(NA_character_)
    }

    normalizePath(
      path,
      winslash = "/",
      mustWork = FALSE
    )
  }

  input_bam_normalized <- normalize_optional(input_bam)
  bam_used_normalized <- normalize_optional(bam_used)

  generated_bam_files <- character(0)

  if (
    !is.na(bam_used_normalized) &&
      !is.na(input_bam_normalized) &&
      !identical(
        tolower(bam_used_normalized),
        tolower(input_bam_normalized)
      )
  ) {
    generated_bam_files <- c(
      bam_used,
      bam_index_used
    )
  }

  feature_files <- file.path(
    output_directory,
    c(
      paste0("SVM.TwoStrands.Training.", output_prefix),
      paste0("SVM.TwoStrands.Target.", output_prefix),
      "TargetPositiveTUMatrix.txt",
      "TargetNegativeTUMatrix.txt",
      "SimulatedPositiveTUMatrix.txt",
      "SimulatedNegativeTUMatrix.txt"
    )
  )

  temporary_files <- file.path(
    output_directory,
    c(
      paste0(output_prefix, "_FinalTUTable_forPlot.clean"),
      paste0(output_prefix, "_FinalTUTable_labelled.tsv"),
      paste0(output_prefix, "_predicted_TUs.bed"),
      paste0(output_prefix, "_result_corrected.bedgraph"),
      paste0(output_prefix, "_alignmentStats.tsv"),
      paste0(output_prefix, "_BAM_flag_summary.txt"),
      paste0(output_prefix, "_QuasR_QC_log.txt"),
      paste0(output_prefix, "_sessionInfo.txt")
    )
  )

  candidates <- unique(
    c(
      na_file,
      chromosome_fasta,
      clean_gff,
      generated_bam_files,
      feature_files,
      temporary_files
    )
  )

  # The BAM and matching index needed for IGV have already been copied into
  # the IGV Results folder. A generated coordinate-sorted working BAM can now
  # be deleted from the result-folder root after its copy is verified.

  candidates <- candidates[
    !is.na(candidates) &
      nzchar(candidates)
  ]

  candidates <- unique(
    normalizePath(
      candidates,
      winslash = "/",
      mustWork = FALSE
    )
  )

  final_files <- unique(
    normalizePath(
      final_files,
      winslash = "/",
      mustWork = FALSE
    )
  )

  protected_files <- unique(
    c(
      final_files,
      normalize_optional(svm_gff),
      normalize_optional(INPUT_BAM),
      normalize_optional(INPUT_GFF),
      normalize_optional(INPUT_FASTA)
    )
  )

  candidates <- setdiff(
    candidates,
    protected_files
  )

  existed <- file.exists(candidates)

  if (any(existed)) {
    unlink(
      candidates[existed],
      recursive = FALSE,
      force = TRUE
    )
  }

  result <- data.frame(
    file = basename(candidates),
    existed = existed,
    deleted = !file.exists(candidates),
    row.names = NULL,
    stringsAsFactors = FALSE
  )

  print(result)

  failed <- candidates[
    existed &
      file.exists(candidates)
  ]

  if (length(failed) > 0L) {
    warning(
      "Some intermediate files could not be deleted: ",
      paste(failed, collapse = " | "),
      call. = FALSE
    )
  }

  invisible(result)
}


# =============================================================================
# 11. RUN THE COMPLETE PIPELINE
# =============================================================================

message_section("rSeqTU COMPLETE PIPELINE")

write_gui_status(
  1L,
  2L,
  "Running",
  "Validating selected input files"
)

assert_directory(OUTPUT_DIR)

IGV_DIR <- file.path(
  OUTPUT_DIR,
  "IGV Results"
)

if (!dir.exists(IGV_DIR)) {
  created_igv_directory <- dir.create(
    IGV_DIR,
    recursive = TRUE,
    showWarnings = FALSE
  )

  if (!isTRUE(created_igv_directory) && !dir.exists(IGV_DIR)) {
    stop(
      "Could not create the IGV Results subfolder: ",
      IGV_DIR,
      call. = FALSE
    )
  }
}

assert_directory(IGV_DIR)

assert_file(INPUT_BAM, "Input BAM")
assert_file(INPUT_GFF, "Input annotation")
assert_file(INPUT_FASTA, "Input FASTA")

write_gui_status(
  2L,
  6L,
  "Running",
  "Checking R packages and dependencies"
)

check_and_install_packages(INSTALL_PACKAGES)

write_gui_status(
  2L,
  13L,
  "Finished",
  "R environment and packages are ready"
)

# Record whether the original BAM index existed before this run.
input_bam_index_before <- find_bam_index(INPUT_BAM)

# Prepare BAM and index.
write_gui_status(
  3L,
  17L,
  "Running",
  "Preparing, sorting and indexing the BAM"
)

bam_ready <- prepare_bam(
  bam_file = INPUT_BAM,
  output_directory = OUTPUT_DIR,
  overwrite = OVERWRITE
)

RETAINED_BAM_INDEX <- if (isTRUE(COPY_BAM_BAI_TO_IGV)) {
  retain_bam_index_in_results(
    bam_file = bam_ready$bam,
    bam_index = bam_ready$index,
    output_directory = IGV_DIR
  )
} else {
  bam_ready$index
}

# Select the exact chromosome from the BAM header.
write_gui_status(
  3L,
  23L,
  "Running",
  "Selecting the chromosome/reference sequence"
)

target_reference <- get_target_reference(
  bam_file = bam_ready$bam,
  bam_index = bam_ready$index,
  input_fasta = INPUT_FASTA,
  input_gff = INPUT_GFF,
  accession = ACCESSION
)

ACCESSION <- target_reference$accession
ACCESSION_FILE_SAFE <- gsub(
  "[^A-Za-z0-9_.-]",
  "_",
  ACCESSION
)

ACCESSION_FILE_DISPLAY <- gsub(
  "_+",
  " ",
  ACCESSION_FILE_SAFE
)

ACCESSION_FILE_DISPLAY <- gsub(
  "\\s+",
  " ",
  trimws(ACCESSION_FILE_DISPLAY)
)

# Generate BAM-level QC before chromosome-specific coverage extraction.
# This summarizes the complete BAM, including all references recorded in it.
if (RUN_QC_STEP) {
  write_gui_status(
    3L,
    30L,
    "Running",
    "Generating the QuasR quality-control report"
  )

  quasr_qc <- run_QuasR_QC(
    bam_file = bam_ready$bam,
    output_directory = OUTPUT_DIR,
    output_prefix = DISPLAY_PREFIX,
    chunk_size = 1000000L,
    overwrite = OVERWRITE
  )
}

# Output files derived from the selected chromosome.
CHROMOSOME_FASTA <- file.path(
  OUTPUT_DIR,
  paste0(ACCESSION_FILE_SAFE, "_only.fna")
)

CLEAN_GFF <- file.path(
  OUTPUT_DIR,
  paste0(ACCESSION_FILE_SAFE, "_rSeqTU_clean.gff")
)

SVM_GFF <- file.path(
  OUTPUT_DIR,
  paste0(ACCESSION_FILE_DISPLAY, " rSeqTU clean for SVM.gff")
)

# Produce chromosome-only per-base coverage.
write_gui_status(
  3L,
  42L,
  "Running",
  "Extracting strand-specific BAM coverage"
)

NA_FILE <- generate_selected_reference_NA(
  bam_file = bam_ready$bam,
  bam_index = bam_ready$index,
  reference_name = target_reference$name,
  reference_length = target_reference$length,
  output_file = NA_FILE,
  min_mapq = MIN_MAPQ,
  min_base_quality = MIN_BASE_QUALITY,
  swap_strands = SWAP_STRANDS,
  overwrite = OVERWRITE
)

write_gui_status(
  3L,
  50L,
  "Running",
  "Validating chromosome coverage"
)

validate_NA_file(
  na_file = NA_FILE,
  reference_length = target_reference$length
)

# Select the complete chromosome sequence.
write_gui_status(
  3L,
  56L,
  "Running",
  "Preparing the chromosome FASTA"
)

CHROMOSOME_FASTA <- prepare_chromosome_fasta(
  input_fasta = INPUT_FASTA,
  accession = ACCESSION,
  fasta_record_name = target_reference$fasta_record_name,
  expected_length = target_reference$length,
  output_fasta = CHROMOSOME_FASTA,
  output_sequence_name = target_reference$name,
  overwrite = OVERWRITE
)

# Create a clean chromosome-only gene GFF.
write_gui_status(
  3L,
  63L,
  "Running",
  "Cleaning the GFF/GFF3 annotation"
)

gff_result <- prepare_rSeqTU_gff(
  input_gff = INPUT_GFF,
  accession = ACCESSION,
  gff_sequence_id = target_reference$gff_sequence_id,
  bam_reference_name = target_reference$name,
  genome_length = target_reference$length,
  output_gff = CLEAN_GFF,
  overwrite = OVERWRITE
)

CLEAN_GFF <- gff_result$file

# TU_SVM hardcodes skip = 7, so create a separate GFF with seven header lines.
write_gui_status(
  3L,
  69L,
  "Running",
  "Preparing the SVM-compatible GFF"
)

SVM_GFF <- create_SVM_gff_with_seven_headers(
  clean_gff = CLEAN_GFF,
  svm_gff = SVM_GFF
)

# Generate feature matrices.
if (RUN_FEATURE_STEP) {
  write_gui_status(
    3L,
    75L,
    "Running",
    "Generating rSeqTU feature matrices"
  )

  run_gen_cTU_data(
    na_file = NA_FILE,
    file_prefix = PREFIX,
    clean_gff = CLEAN_GFF,
    chromosome_fasta = CHROMOSOME_FASTA,
    output_directory = OUTPUT_DIR,
    overwrite = OVERWRITE
  )
}

# Run SVM prediction. Initialize objects first so the completion summary is safe
# even when a user executes sections interactively or disables a stage.
svm_results <- NULL
final_results <- NULL
igv_results <- NULL

if (isTRUE(RUN_SVM_STEP)) {
  write_gui_status(
    3L,
    85L,
    "Running",
    "Predicting transcription units with the SVM"
  )

  message_section("STARTING SVM PREDICTION STAGE")

  svm_results <- run_TU_SVM(
    na_file = NA_FILE,
    svm_gff = SVM_GFF,
    output_prefix = PREFIX,
    genome_name = target_reference$name,
    output_directory = OUTPUT_DIR,
    seed = RANDOM_SEED,
    overwrite = OVERWRITE
  )

  if (is.null(svm_results) ||
      is.null(svm_results$table) ||
      !file.exists(svm_results$table)) {
    stop(
      "The SVM stage did not provide a final TU table. ",
      "Check the console output immediately above this message.",
      call. = FALSE
    )
  }

  write_gui_status(
    4L,
    93L,
    "Running",
    "Finalizing the TU Excel workbook and strand-aware bedGraph"
  )

  final_results <- postprocess_TU_results(
    final_table_file = svm_results$table,
    chromosome_name = target_reference$name,
    internal_prefix = PREFIX,
    display_prefix = DISPLAY_PREFIX,
    output_directory = OUTPUT_DIR,
    igv_directory = IGV_DIR
  )

  if (is.null(final_results)) {
    stop("TU post-processing did not return results.", call. = FALSE)
  }

  write_gui_status(
    4L,
    95L,
    "Running",
    "Creating the IGV Results folder"
  )

  igv_results <- prepare_igv_result_bundle(
    bam_file = bam_ready$bam,
    bam_index = RETAINED_BAM_INDEX,
    bedgraph_file = final_results$bedgraph_file,
    annotation_file = INPUT_GFF,
    fasta_file = INPUT_FASTA,
    igv_directory = IGV_DIR,
    copy_bam_bai = COPY_BAM_BAI_TO_IGV
  )
}

# Confirm that all requested final outputs exist before cleanup.
required_final_files <- c(
  if (isTRUE(RUN_QC_STEP)) quasr_qc$qc_pdf else character(0),
  if (!is.null(final_results)) final_results$plot_file else character(0),
  SVM_GFF,
  if (!is.null(igv_results)) igv_results$files else character(0)
)

expected_final_file_count <- if (isTRUE(COPY_BAM_BAI_TO_IGV)) 8L else 6L

if (length(required_final_files) != expected_final_file_count) {
  stop(
    "The pipeline did not produce the expected retained files. ",
    "The QC PDF, TU Excel workbook, cleaned SVM GFF, IGV bedGraph, annotation and FASTA ",
    if (isTRUE(COPY_BAM_BAI_TO_IGV)) "plus the requested BAM and BAI copy " else "",
    "must all exist before cleanup.",
    call. = FALSE
  )
}

if (!all(file.exists(required_final_files))) {
  stop(
    "One or more requested final files are missing: ",
    paste(
      required_final_files[!file.exists(required_final_files)],
      collapse = " | "
    ),
    call. = FALSE
  )
}

if (any(file.info(required_final_files)$size <= 0L)) {
  stop(
    "One or more requested final files are empty.",
    call. = FALSE
  )
}

# Delete generated intermediates only after all final outputs are valid.
write_gui_status(
  4L,
  97L,
  "Running",
  "Verifying outputs and deleting intermediate files"
)

if (isTRUE(DELETE_INTERMEDIATE_FILES)) {
  delete_generated_intermediates(
    input_bam = INPUT_BAM,
    input_bam_index_before = input_bam_index_before,
    bam_used = bam_ready$bam,
    bam_index_used = bam_ready$index,
    na_file = NA_FILE,
    chromosome_fasta = CHROMOSOME_FASTA,
    clean_gff = CLEAN_GFF,
    svm_gff = SVM_GFF,
    output_prefix = PREFIX,
    output_directory = OUTPUT_DIR,
    final_files = required_final_files
  )
}

write_gui_status(
  4L,
  100L,
  "Finished",
  "All requested outputs were created successfully"
)

message_section("PIPELINE COMPLETED")

final_result_labels <- c(
  "QuasR QC report",
  "Final TU Excel workbook",
  "Cleaned SVM GFF",
  if (isTRUE(COPY_BAM_BAI_TO_IGV)) c("IGV BAM", "IGV BAM index") else character(0),
  "IGV strand-aware bedGraph",
  "IGV input annotation",
  "IGV input FASTA"
)

final_summary <- data.frame(
  result = final_result_labels,
  file = required_final_files,
  exists = file.exists(required_final_files),
  size_KB = round(file.info(required_final_files)$size / 1024, 2),
  row.names = NULL,
  stringsAsFactors = FALSE
)

print(final_summary)

cat(
  "\nForward TUs in bedGraph: ",
  final_results$forward_TUs,
  "\n",
  sep = ""
)

cat(
  "Reverse TUs in bedGraph: ",
  final_results$reverse_TUs,
  "\n",
  sep = ""
)

cat(
  "\nThe requested outputs and IGV Results folder were retained. BAM/BAI copy: ",
  if (isTRUE(COPY_BAM_BAI_TO_IGV)) "included" else "not requested",
  ".\n",
  sep = ""
)

flush.console()

# Explicitly return a successful process status to the Windows GUI after all
# outputs have been verified and the 100% Finished marker has been written.
quit(
  save = "no",
  status = 0L,
  runLast = FALSE
)
