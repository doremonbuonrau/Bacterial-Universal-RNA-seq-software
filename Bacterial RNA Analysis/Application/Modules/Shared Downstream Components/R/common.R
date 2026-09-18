suppressPackageStartupMessages({
  library(jsonlite)
})

read_config <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) < 1L) stop("A JSON configuration file is required.")
  fromJSON(args[[1]], simplifyVector = TRUE)
}

read_table_auto <- function(path, check.names = FALSE) {
  if (!file.exists(path)) stop("Input file not found: ", path)
  ext <- tolower(tools::file_ext(path))
  sep <- if (ext == "csv") "," else "\t"
  out <- read.delim(path, sep = sep, header = TRUE, quote = "\"", comment.char = "", check.names = check.names,
                    stringsAsFactors = FALSE)
  if (ncol(out) < 1L) stop("No columns were found in: ", path)
  out
}

write_tsv <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  write.table(x, path, sep = "\t", row.names = FALSE, quote = FALSE, na = "")
}

write_json_file <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(x, path, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
}

as_flag <- function(x, default = FALSE) {
  if (is.null(x) || length(x) == 0L || is.na(x)) return(default)
  isTRUE(x) || identical(tolower(as.character(x)), "true") || identical(as.character(x), "1")
}

safe_numeric <- function(x, name) {
  out <- suppressWarnings(as.numeric(x))
  if (any(is.na(out) & !is.na(x))) stop("Column '", name, "' contains non-numeric values.")
  out
}

standardize_gene_column <- function(df, requested = NULL) {
  gene_col <- requested
  if (is.null(gene_col) || !nzchar(gene_col) || !gene_col %in% colnames(df)) gene_col <- colnames(df)[1]
  colnames(df)[match(gene_col, colnames(df))] <- "gene_id"
  df$gene_id <- as.character(df$gene_id)
  if (any(!nzchar(df$gene_id)) || anyDuplicated(df$gene_id)) stop("Gene identifiers must be non-empty and unique.")
  df
}

standardize_sample_column <- function(df, requested = NULL) {
  sample_col <- requested
  if (is.null(sample_col) || !nzchar(sample_col) || !sample_col %in% colnames(df)) sample_col <- colnames(df)[1]
  colnames(df)[match(sample_col, colnames(df))] <- "sample_id"
  df$sample_id <- as.character(df$sample_id)
  if (any(!nzchar(df$sample_id)) || anyDuplicated(df$sample_id)) stop("Sample identifiers must be non-empty and unique.")
  df
}

check_packages <- function(packages) {
  missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) stop("Missing R packages: ", paste(missing, collapse = ", "), ". Run the downstream environment installer.")
}

session_lines <- function() capture.output(sessionInfo())

advanced_package_options <- function(config, key) {
  collection <- config$advanced_package_options
  if (is.null(collection) || is.null(collection[[key]])) return(list())
  encoded <- trimws(as.character(collection[[key]])[1])
  if (!nzchar(encoded) || identical(encoded, "{}")) return(list())
  parsed <- tryCatch(
    jsonlite::fromJSON(encoded, simplifyVector = TRUE),
    error = function(error) stop("Invalid advanced package options for '", key, "': ", conditionMessage(error))
  )
  if (!is.list(parsed) || is.null(names(parsed)) || any(!nzchar(names(parsed)))) {
    stop("Advanced package options for '", key, "' must be a JSON object with named arguments.")
  }
  parsed
}

summarize_call_value <- function(value) {
  if (is.null(value)) return("NULL")
  if (inherits(value, "formula")) return(paste(deparse(value), collapse = " "))
  if (is.function(value)) return("<function>")
  if (is.atomic(value) && length(value) <= 12L) {
    encoded <- tryCatch(
      jsonlite::toJSON(value, auto_unbox = length(value) == 1L, null = "null", na = "null"),
      error = function(error) NULL
    )
    if (!is.null(encoded)) return(as.character(encoded))
  }
  dimensions <- dim(value)
  if (!is.null(dimensions)) {
    return(paste0("<", paste(class(value), collapse = "/"), " ", paste(dimensions, collapse = "x"), ">"))
  }
  paste0("<", paste(class(value), collapse = "/"), " length=", length(value), ">")
}

call_with_advanced_options <- function(fun, base_args, config, key, display_name = key,
                                       protected = character()) {
  if (!is.function(fun)) stop("Internal error: '", display_name, "' is not callable.")
  if (!is.list(base_args) || is.null(names(base_args)) || any(!nzchar(names(base_args)))) {
    stop("Internal error: base arguments for '", display_name, "' must be a named list.")
  }
  overrides <- advanced_package_options(config, key)
  conflicts <- intersect(names(overrides), protected)
  if (length(conflicts)) {
    stop("Advanced options for ", display_name, " cannot replace pipeline-protected arguments: ",
         paste(conflicts, collapse = ", "), ".")
  }
  formal_names <- names(formals(fun))
  if (!is.null(formal_names) && !"..." %in% formal_names) {
    unknown <- setdiff(names(overrides), formal_names)
    if (length(unknown)) {
      stop("Unknown advanced option(s) for ", display_name, ": ", paste(unknown, collapse = ", "),
           ". These names are not supported by the installed package version.")
    }
  }
  effective <- base_args
  for (name in names(overrides)) effective[name] <- list(overrides[[name]])
  rendered <- vapply(names(effective), function(name) {
    paste0(name, " = ", summarize_call_value(effective[[name]]))
  }, character(1))
  message("THIRD-PARTY FUNCTION CALL | ", display_name, "(", paste(rendered, collapse = ", "), ")")
  if (length(overrides)) {
    message("ADVANCED OVERRIDES | ", display_name, " | ",
            jsonlite::toJSON(overrides, auto_unbox = TRUE, null = "null", na = "null"))
  } else {
    message("ADVANCED OVERRIDES | ", display_name, " | {} (package/pipeline defaults)")
  }
  do.call(fun, effective)
}
