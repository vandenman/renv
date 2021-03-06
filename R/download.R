
# download a file from 'url' to file 'destfile'. the 'type'
# argument tells us the remote type, which is used to motivate
# what form of authentication is appropriate; the 'quiet'
# argument is used to display / suppress output. use 'headers'
# (as a named character vector) to supply additional headers
download <- function(url, destfile, type = NULL, quiet = FALSE, headers = NULL) {

  # allow for user-defined overrides
  override <- getOption("renv.download.override")
  if (is.function(override)) {

    result <- catch(
      override(
        url      = url,
        destfile = destfile,
        quiet    = quiet,
        mode     = "wb",
        headers  = headers
      )
    )

    if (inherits(result, "error"))
      renv_download_error(result, "%s", conditionMessage(result))

    return(destfile)

  }

  if (quiet)
    renv_scope_options(renv.verbose = FALSE)

  # normalize separators (file URIs should normally use forward
  # slashes, even on Windows where the native separator is backslash)
  url      <- chartr("\\", "/", url)
  destfile <- chartr("\\", "/", destfile)

  # notify user we're about to try downloading
  vwritef("Retrieving '%s' ...", url)

  # add custom headers as appropriate for the URL
  headers <- c(headers, renv_download_custom_headers(url))

  # handle local files by just copying the file
  if (renv_download_local(url, destfile, headers))
    return(destfile)

  # on Windows, try using our local curl binary if available
  renv_scope_downloader()

  # if the file already exists, compare its size with
  # the server's reported size for that file
  info <- file.info(destfile, extra_cols = FALSE)
  if (identical(info$isdir, FALSE)) {
    size <- renv_download_size(url, type, headers)
    if (info$size == size) {
      vwritef("\tOK [file is up to date]")
      return(destfile)
    }
  }

  # back up a pre-existing file if necessary
  callback <- renv_file_backup(destfile)
  on.exit(callback(), add = TRUE)

  # form path to temporary file
  tempfile <- renv_tempfile_path(tmpdir = dirname(destfile))

  # request the download
  before <- Sys.time()

  status <- renv_download_impl(
    url      = url,
    destfile = tempfile,
    type     = type,
    request  = "GET",
    headers  = headers
  )

  after <- Sys.time()

  # check for failure
  if (inherits(status, "error"))
    renv_download_error(url, "%s", conditionMessage(status))

  if (status != 0L)
    renv_download_error(url, "error code %i", status)

  if (!file.exists(tempfile))
    renv_download_error(url, "%s", "unknown reason")

  # double-check archives are readable
  status <- renv_download_check_archive(tempfile)
  if (inherits(status, "error"))
    renv_download_error(url, "%s", "archive cannot be read")

  # everything looks ok: report success
  renv_download_report(after - before, tempfile)

  # move the file to the requested location
  renv_file_move(tempfile, destfile)

  # and return path to successfully retrieved file
  destfile

}

# NOTE: only 'GET' and 'HEAD' are supported
#
# each downloader should return 0 on success
renv_download_impl <- function(url, destfile, type = NULL, request = "GET", headers = NULL) {

  # normalize separators (file URIs should normally use forward
  # slashes, even on Windows where the native separator is backslash)
  url      <- chartr("\\", "/", url)
  destfile <- chartr("\\", "/", destfile)

  # select the appropriate downloader
  downloader <- switch(
    renv_download_method(),
    curl = renv_download_curl,
    wget = renv_download_wget,
    renv_download_default
  )

  # run downloader, catching errors
  catch(downloader(url, destfile, type, request, headers))

}

renv_download_default_mode <- function(url, method) {

  mode <- "wb"

  fixup <-
    renv_platform_windows() &&
    identical(method, "wininet") &&
    substring(url, 1L, 5L) == "file:"

  if (fixup)
    mode <- "w+b"

  mode

}

renv_download_default <- function(url, destfile, type, request, headers) {

  # custom request types are not supported with the default downloader
  if (request != "GET")
    stopf("the default downloader does not support %s requests", request)

  # try and ensure headers are set for older versions of R
  headers <- c(headers, renv_download_auth(url, type))
  renv_download_default_agent_scope(headers)

  # on Windows, prefer 'wininet' as most users will have already configured
  # authentication etc. to work with this protocol
  methods <- c(
    Sys.getenv("RENV_DOWNLOAD_METHOD", unset = NA),
    Sys.getenv("RENV_DOWNLOAD_FILE_METHOD", unset = NA),
    if (renv_platform_windows()) "wininet" else "auto"
  )

  method <- Find(Negate(is.na), methods)

  # headers _must_ be NULL rather than zero-length character
  if (length(headers) == 0)
    headers <- NULL

  mode <- renv_download_default_mode(url, method)

  # handle absence of 'headers' argument in older versions of R
  args <- list(url      = url,
               destfile = destfile,
               method   = method,
               headers  = headers,
               mode     = mode,
               quiet    = TRUE)

  fmls <- formals(download.file)
  args <- keep(args, names(fmls))

  renv_download_trace_begin(url, method)
  if (renv_download_trace())
    str(args)

  do.call(download.file, args)

}

renv_download_default_agent_scope <- function(headers) {

  if (empty(headers))
    return(FALSE)

  if (getRversion() >= "3.6.0")
    return(FALSE)

  envir <- parent.frame()
  renv_download_default_agent_scope_impl(headers, envir)

}

renv_download_default_agent_scope_impl <- function(headers, envir = NULL) {

  envir <- envir %||% parent.frame()

  utils <- asNamespace("utils")
  makeUserAgent <- utils$makeUserAgent

  ok <-
    is.function(makeUserAgent) &&
    identical(formals(makeUserAgent), pairlist(format = TRUE))

  if (!ok)
    return(FALSE)

  do.call("unlockBinding", list("makeUserAgent", utils))
  defer(do.call("lockBinding", list("makeUserAgent", utils)), envir = envir)

  agent <- makeUserAgent(FALSE)
  all <- c("User-Agent" = agent, headers)
  headertext <- paste0(names(all), ": ", all, "\r\n", collapse = "")

  assign("makeUserAgent", envir = utils, function(format = TRUE) {
    if (format) headertext else agent
  })

  return(TRUE)

}

renv_download_curl <- function(url, destfile, type, request, headers) {

  renv_download_trace_begin(url, "curl")

  file <- renv_tempfile_path("renv-download-config-")

  fields <- c(
    "user-agent" = renv_http_useragent(),
    "url"        = url,
    "output"     = destfile
  )

  # set connect timeout
  timeout <- config$connect.timeout()
  if (is.numeric(timeout))
    fields[["connect-timeout"]] <- timeout

  # set number of retries
  retries <- config$connect.retry()
  if (is.numeric(retries))
    fields[["retry"]] <- retries

  # set up authentication headers
  auth <- renv_download_auth(url, type)
  if (length(auth)) {
    authtext <- paste(names(auth), auth, sep = ": ")
    names(authtext) <- "header"
    fields <- c(fields, authtext)
  }

  # add other custom headers
  if (length(headers)) {
    lines <- paste(names(headers), headers, sep = ": ")
    names(lines) <- "header"
    fields <- c(fields, lines)
  }

  # join together
  keys <- names(fields)
  vals <- shQuote(fields, type = "cmd")
  text <- paste(keys, vals, sep = " = ")

  # add in stand-along flags
  flags <- c("location", "fail", "silent", "show-error")
  if (request == "HEAD")
    flags <- c(flags, "head", "include")

  # put it all together
  text <- c(flags, text)

  writeLines(text, con = file)
  renv_download_trace_request(text)

  # generate the arguments to be passed to 'curl'
  args <- stack()

  # include anything provided explicitly in 'download.file.extra' here
  extra <- getOption("download.file.extra")
  if (length(extra))
    args$push(extra)

  # add in any user configuration files
  userconfig <- getOption(
    "renv.curl.config",
    renv_download_curl_config()
  )

  for (entry in userconfig)
    if (file.exists(entry))
      args$push("--config", shQuote(entry))

  # add in our own config file (the actual request)
  args$push("--config", shQuote(file))

  # perform the download
  output <- suppressWarnings(
    system2("curl", args$data(), stdout = TRUE, stderr = TRUE)
  )

  renv_download_trace_result(output)

  # report non-zero status as warning
  status <- attr(output, "status", exact = TRUE) %||% 0L
  if (status != 0L)
    warning(output, call. = FALSE)

  status

}

renv_download_curl_config <- function() {

  rc <- if (renv_platform_windows()) "_curlrc" else ".curlrc"

  homes <- c(
    Sys.getenv("CURL_HOME"),
    Sys.getenv("HOME"),
    Sys.getenv("R_USER"),
    path.expand("~/")
  )

  # nocov start
  if (renv_platform_windows()) {
    extra <- c(
      Sys.getenv("APPDATA"),
      file.path(Sys.getenv("USERPROFILE"), "Application Data"),
      dirname(Sys.which("curl"))
    )
    homes <- c(homes, extra)
  }
  # nocov end

  homes <- Filter(nzchar, homes)

  for (home in homes) {
    path <- file.path(home, rc)
    if (file.exists(path))
      return(path)
  }

  NULL

}

# nocov start

renv_download_wget <- function(url, destfile, type, request, headers) {

  renv_download_trace_begin(url, "wget")

  config <- renv_tempfile_path("renv-download-config-")

  fields <- c(
    "user-agent" = renv_http_useragent(),
    "quiet"      = "on"
  )

  auth <- renv_download_auth(url, type)
  if (length(auth)) {
    authtext <- paste(names(auth), auth, sep = ": ")
    names(authtext) <- "header"
    fields <- c(fields, authtext)
  }

  if (length(headers)) {
    lines <- paste(names(headers), headers, sep = ": ")
    names(lines) <- "header"
    fields <- c(fields, lines)
  }

  keys <- names(fields)
  vals <- unlist(fields)
  text <- paste(keys, vals, sep = " = ")

  writeLines(text, con = config)
  renv_download_trace_request(text)

  args <- stack()

  extra <- getOption("download.file.extra")
  if (length(extra))
    args$push(extra)

  args$push("--config", shQuote(config))

  # NOTE: '-O' does not write headers to file; we need to manually redirect
  # in that case
  status <- if (request == "HEAD") {
    args$push("--server-response", "--spider")
    args$push(">", shQuote(destfile), "2>&1")
    cmdline <- paste("wget", paste(args$data(), collapse = " "))
    return(suppressWarnings(system(cmdline)))
  }

  args$push("-O", shQuote(destfile))
  args$push(shQuote(url))

  output <- suppressWarnings(
    system2("wget", args$data(), stdout = TRUE, stderr = TRUE)
  )

  renv_download_trace_result(output)

  status <- attr(output, "status", exact = TRUE) %||% 0L
  if (status != 0L)
    warning(output, call. = FALSE)

  status

}

# nocov end

renv_download_auth_type <- function(url) {

  github_hosts <- c(
    "https://api.github.com/",
    "https://raw.githubusercontent.com/"
  )

  for (host in github_hosts)
    if (startswith(url, host))
      return("github")

  gitlab_hosts <- c(
    "https://gitlab.com/"
  )

  for (host in gitlab_hosts)
    if (startswith(url, host))
      return("gitlab")

  bitbucket_hosts <- c(
    "https://api.bitbucket.org/",
    "https://bitbucket.org/"
  )

  for (host in bitbucket_hosts)
    if (startswith(url, host))
      return("bitbucket")

  "unknown"

}

renv_download_auth <- function(url, type) {

  type <- tolower(type %||% renv_download_auth_type(url))
  switch(
    type,
    bitbucket = renv_download_auth_bitbucket(),
    github = renv_download_auth_github(),
    gitlab = renv_download_auth_gitlab(),
    character()
  )

}

renv_download_auth_bitbucket <- function() {

  user <-
    Sys.getenv("BITBUCKET_USER", unset = NA) %NA%
    Sys.getenv("BITBUCKET_USERNAME", unset = NA)

  pass <-
    Sys.getenv("BITBUCKET_PASS", unset = NA) %NA%
    Sys.getenv("BITBUCKET_PASSWORD", unset = NA)

  if (is.na(user) || is.na(pass))
    return(character())

  userpass <- paste(user, pass, sep = ":")
  c("Authorization" = paste("Basic", renv_base64_encode(userpass)))

}

renv_download_auth_github <- function() {

  pat <- Sys.getenv("GITHUB_PAT", unset = NA)
  if (is.na(pat))
    return(character())

  c("Authorization" = paste("token", pat))

}

renv_download_auth_gitlab <- function() {

  pat <- Sys.getenv("GITLAB_PAT", unset = NA)
  if (is.na(pat))
    return(character())

  c("Private-Token" = pat)

}

renv_download_headers <- function(url, type, headers) {

  # check for compatible download method
  method <- renv_download_method()
  if (!method %in% c("libcurl", "curl", "wget"))
    return(list())

  # perform the download
  file <- renv_tempfile_path("renv-headers-")

  status <- renv_download_impl(
    url      = url,
    destfile = file,
    type     = type,
    request  = "HEAD",
    headers  = headers
  )

  # check for failure
  failed <-
    inherits(status, "error") ||
    !identical(status, 0L) ||
    !file.exists(file)

  if (failed) {
    unlink(file)
    return(list())
  }

  # read the downloaded headers
  contents <- read(file)

  # if redirects were required, each set of headers will
  # be reported separately, so just report the final set
  # of headers (ie: ignore redirects)
  splat <- strsplit(contents, "\n\n", fixed = TRUE)[[1]]
  text <- strsplit(splat[[length(splat)]], "\n", fixed = TRUE)[[1]]

  # keep only header lines
  lines <- grep(":", text, fixed = TRUE, value = TRUE)
  headers <- catch(renv_properties_read(text = lines))
  names(headers) <- tolower(names(headers))
  if (inherits(headers, "error"))
    return(list())

  headers

}

renv_download_size <- function(url, type = NULL, headers = NULL) {

  headers <- catch(renv_download_headers(url, type, headers))
  if (inherits(headers, "error"))
    return(-1L)

  size <- headers[["x-gitlab-size"]]
  if (!is.null(size))
    return(as.numeric(size))

  size <- headers[["content-length"]]
  if (!is.null(size))
    return(as.numeric(size))

  return(-1L)

}

# select an appropriate download file method. we prefer curl
# when available as it's the most user-customizable of all the
# download methods; when not available, we fall back to libcurl
# and wget (in that order). note that we don't want to use the
# internal or wininet downloaders as we cannot set custom headers
# with those methods. users can force a method with the
# RENV_DOWNLOAD_FILE_METHOD environment variable but we generally
# want to override a user-specified 'download.file.method'
renv_download_method <- function() {

  method <- Sys.getenv("RENV_DOWNLOAD_METHOD", unset = NA)
  if (!is.na(method))
    return(method)

  method <- Sys.getenv("RENV_DOWNLOAD_FILE_METHOD", unset = NA)
  if (!is.na(method))
    return(method)

  # prefer curl if available
  if (nzchar(Sys.which("curl")))
    return("curl")

  # if curl is not available, use libcurl if available
  libcurl <- capabilities("libcurl")
  if (length(libcurl) && libcurl)
    return("libcurl")

  # on windows, just use wininet here
  if (renv_platform_windows())
    return("wininet")

  # if neither curl nor libcurl is available, prefer wget
  if (nzchar(Sys.which("wget")))
    return("wget")

  # all else fails, use the internal downloader
  "internal"

}

renv_download_report <- function(elapsed, file) {

  if (!renv_verbose())
    return()

  time <- round(elapsed, 1)

  info <- file.info(file, extra_cols = FALSE)
  size <- structure(info$size, class = "object_size")

  fmt <- "\tOK [downloaded %s in %s]"
  vwritef(fmt, format(size, units = "auto"), format(time, units = "auto"))

}

renv_download_check_archive <- function(destfile) {

  # validate the file exists
  if (!file.exists(destfile))
    return(FALSE)

  # validate archive type
  type <- renv_archive_type(destfile)
  if (type == "unknown")
    return(FALSE)

  # try listing files in the archive
  tryCatch({renv_archive_list(destfile); TRUE}, error = identity)

}

renv_download_local <- function(url, destfile, headers) {

  # only ever used for downloads from file URIs and server URIs
  ok <-
    grepl("^file:", url) ||
    !grepl("^[a-zA-Z]+://", url)

  if (!ok)
    return(FALSE)

  methods <- list(
    renv_download_local_copy,
    renv_download_local_default
  )

  for (method in methods) {

    # perform the copy
    before <- Sys.time()
    status <- catch(method(url, destfile, headers))
    after  <- Sys.time()

    # check for success
    if (!identical(status, TRUE))
      next

    # report download summary
    renv_download_report(after - before, destfile)

    return(TRUE)

  }

  FALSE

}

renv_download_local_copy <- function(url, destfile, headers) {

  # remove file prefix (to get path to local / server file)
  url <- case(
    startswith(url, "file:///") ~ substring(url, 8L),
    startswith(url, "file://")  ~ substring(url, 6L),
    startswith(url, "file:")    ~ substring(url, 6L),
    TRUE                        ~ url
  )

  # fix up file URIs to local paths on Windows
  if (renv_platform_windows()) {
    badpath <- grepl("^/[a-zA-Z]:", url)
    if (badpath)
      url <- substring(url, 2L)
  }

  # attempt to copy
  ensure_parent_directory(destfile)
  status <- catchall(renv_file_copy(url, destfile, overwrite = TRUE))
  if (!identical(status, TRUE))
    return(FALSE)

  TRUE

}

renv_download_local_default <- function(url, destfile, headers) {

  status <- renv_download_impl(
    url      = url,
    destfile = destfile,
    headers  = headers
  )

  identical(status, 0L)

}

renv_download_custom_headers <- function(url) {

  headers <- getOption("renv.download.headers")
  if (is.null(headers))
    return(character())

  if (!is.function(headers))
    stopf("'renv.download.headers' is not a function")

  headers <- invoke(headers, url)
  if (empty(headers))
    return(character())

  if (is.list(headers))
    headers <- unlist(headers, recursive = FALSE, use.names = TRUE)

  if (!is.character(headers) || is.null(names(headers)))
    stop("invocation of 'renv.download.headers' did not return a named character vector")

  headers

}

renv_download_available <- function(url) {

  # normalize separators (file URIs should normally use forward
  # slashes, even on Windows where the native separator is backslash)
  url <- chartr("\\", "/", url)

  # on Windows, try using our local curl binary if available
  renv_scope_downloader()

  # if we're not using curl, then use fallback method
  method <- renv_download_method()
  if (!identical(method, "curl"))
    return(renv_download_available_fallback(url))

  # otherwise, try a couple candidate methods
  methods <- list(
    renv_download_available_headers,
    renv_download_available_range
  )

  for (method in methods) {
    result <- catch(method(url))
    if (identical(result, TRUE))
      return(TRUE)
  }

  FALSE

}

renv_download_available_headers <- function(url) {

  status <- catchall(
    renv_download_headers(
      url     = url,
      type    = NULL,
      headers = renv_download_custom_headers(url)
    )
  )

  if (inherits(status, "condition"))
    return(FALSE)

  is.list(status) && length(status)

}

renv_download_available_range <- function(url) {

  destfile <- renv_tempfile_path("renv-download-")

  # instruct curl to request only first byte
  extra <- c(getOption("download.file.extra"), "-r 0-0")
  renv_scope_options(download.file.extra = paste(extra, collapse = " "))

  # perform the download
  status <- catchall(
    renv_download_curl(
      url      = url,
      destfile = destfile,
      type     = NULL,
      request  = "GET",
      headers  = renv_download_custom_headers(url)
    )
  )

  if (inherits(status, "condition"))
    return(FALSE)

  # check for success
  identical(status, 0L)

}

renv_download_available_fallback <- function(url) {

  destfile <- renv_tempfile_path("renv-download-")

  # just try downloading the requested URL
  status <- catchall(
    renv_download_impl(
      url      = url,
      destfile = destfile,
      type     = NULL,
      request  = "GET",
      headers  = renv_download_custom_headers(url)
    )
  )

  if (inherits(status, "condition"))
    return(FALSE)

  identical(status, 0L)

}

renv_download_error <- function(url, fmt, ...) {
  msg <- sprintf(fmt, ...)
  stopf("failed to retrieve '%s' [%s]", url, msg, call. = FALSE)
}

renv_download_trace <- function() {
  getOption("renv.download.trace", default = FALSE)
}

renv_download_trace_begin <- function(url, type) {

  if (!renv_download_trace())
    return()

  fmt <- "Downloading '%s' [%s]"
  msg <- sprintf(fmt, url, type)

  title <- header(msg, n = 78L)
  writeLines(c(title, ""))

}

renv_download_trace_request <- function(text) {

  if (!renv_download_trace())
    return()

  title <- header("Request", n = 78L, prefix = "##")
  writeLines(c(title, text, ""))

}

renv_download_trace_result <- function(output) {

  if (!renv_download_trace())
    return()

  title <- header("Output", prefix = "##", n = 78L)
  text <- if (empty(output)) "[no output generated]" else output
  all <- c(title, text, "")
  writeLines(all)

  status <- attr(output, "status", exact = TRUE) %||% 0L
  title <- header("Status", prefix = "##", n = 78L)
  all <- c(title, status, "")
  writeLines(all)

}
