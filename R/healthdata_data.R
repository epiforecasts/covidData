#' Assemble a data frame of incident hospitalizations due to
#' COVID-19 as they were available as of a specified issue date.
#'
#' @param issue_date character issue date (i.e. report date) to use for
#' constructing truths in format 'yyyy-mm-dd'
#' @param spatial_resolution character vector specifying spatial unit types to
#' include: state' and/or 'national'
#' @param temporal_resolution character vector specifying temporal resolution
#' to include: 'daily' or 'weekly'
#' @param measure character vector specifying measure of covid prevalence:
#' must be 'hospitalizations'
#' @param replace_negatives boolean to replace negative incs with imputed data
#' Currently only FALSE is supported
#' @param adjustment_cases character vector specifying times and locations with
#' reporting anomalies to adjust.  Only the value "none" is currently supported
#' @param adjustment_method string specifying how anomalies are adjusted.
#' Only the value "none" is currently supported.
#'
#' @return data frame with columns location (fips code), date, inc, and cum
#' all values of cum will currently be NA
#'
#' @export
load_healthdata_data <- function(
    issue_date = NULL,
    as_of = NULL,
    spatial_resolution = "state",
    temporal_resolution = "weekly",
    measure = "hospitalizations",
    replace_negatives = FALSE,
    adjustment_cases = "none",
    adjustment_method = "none") {
  # validate measure and pull in correct data set
  measure <- match.arg(measure, choices = c("hospitalizations"))

  healthdata_data <- covidData::healthdata_hosp_data

  # validate issue_date and as_of
  if (!missing(issue_date) && !missing(as_of) &&
      !is.null(issue_date) && !is.null(as_of)) {
    stop("Cannot provide both arguments issue_date and as_of to load_healthcare_data.")
  } else if (is.null(issue_date) && is.null(as_of)) {
    issue_date <- max(healthdata_data$issue_date)
  } else if (!is.null(as_of)) {
    avail_issues <- healthdata_data$issue_date[
        healthdata_data$issue_date <= as.character(as_of)
      ]

    if (length(avail_issues) == 0) {
      stop("Provided as_of date is earlier than all available issue dates.")
    } else {
      issue_date <- max(avail_issues)
    }
  } else {
    issue_date <- as.character(lubridate::ymd(issue_date))
  }

  if (!(issue_date %in% healthdata_data$issue_date)) {
    stop(paste0(
      'Invalid issue date; must be one of: ',
      paste0(healthdata_data$issue_date, collapse = ', ')
    ))
  }

  # validate spatial_resolution
  spatial_resolution <- match.arg(
    spatial_resolution,
    choices = c("state", "national"),
    several.ok = TRUE
  )

  # validate temporal_resolution
  temporal_resolution <- match.arg(
    temporal_resolution,
    choices = c("daily", "weekly"),
    several.ok = FALSE
  )

  # validate replace_negatives
  if (replace_negatives) {
    stop("Currently, only replace_negatives = FALSE is supported")
  }

  # validate adjustment_cases and adjustment_method
  adjustment_cases <- match.arg(
    adjustment_cases,
    choices = "none",
    several.ok = FALSE
  )

  adjustment_method <- match.arg(
    adjustment_method,
    choices = "none",
    several.ok = FALSE
  )

  healthdata_data <- healthdata_data %>%
    dplyr::filter(issue_date == UQ(issue_date)) %>%
    dplyr::pull(data) %>%
    `[[`(1)

  # drop results for irrelevant locations
  all_locations <- unique(healthdata_data$location)
  locations_to_keep <- NULL
  if ("state" %in% spatial_resolution) {
    locations_to_keep <- all_locations[all_locations != "US"]
  }

  if ("national" %in% spatial_resolution) {
    locations_to_keep <- c(locations_to_keep, "US")
  }

  results <- healthdata_data %>%
    dplyr::filter(location %in% locations_to_keep)

  # aggregate daily incidence to weekly incidence
  if (temporal_resolution == "weekly") {
    results <- results %>%
      dplyr::mutate(
        sat_date = lubridate::ceiling_date(
          lubridate::ymd(date), unit = "week") - 1
      ) %>%
      dplyr::group_by(location) %>%
      # if the last week is not complete, drop all observations from the
      # previous Saturday in that week
      dplyr::filter(
        if (max(date) < max(sat_date)) date <= max(sat_date) - 7 else TRUE
      ) %>%
      dplyr::ungroup() %>%
      dplyr::select(-date) %>%
      dplyr::rename(date = sat_date) %>%
      dplyr::group_by(location, date) %>%
      dplyr::summarize(inc = sum(inc, na.rm = FALSE)) %>%
      dplyr::ungroup()
  }

  # aggregate inc to get the correct cum
  results <- results %>%
    dplyr::mutate(
      date = lubridate::ymd(date),
      cum = results %>%
        dplyr::group_by(location) %>%
        dplyr::mutate(cum = cumsum(inc)) %>%
        dplyr::ungroup() %>%
        dplyr::pull(cum)
    )

  return(results)
}


#' Construct a merged healthdata data set for a single issue date by pulling
#' from a timeseries update if one is available, or by augmenting the last time
#' series update on or before the issue date with daily updates that were made
#' after the last time series update and on or before the issue date
#' 
#' @param issue_date issue date
#' @param healthdata_hosp_data_ts tibble of issue_date and data reported that
#' date
#' @param healthdata_hosp_data_daily tibble of issue_date, date, and data
#' reported
#' 
#' @return tibble of issue_date and data reported on or by that date
build_healthdata_data <- function(
  issue_date,
  healthdata_hosp_data_ts,
  healthdata_hosp_data_daily
  ) {
  if (issue_date %in% healthdata_hosp_data_ts$issue_date) {
    result <- healthdata_hosp_data_ts %>%
      dplyr::filter(issue_date == UQ(issue_date))
  } else if (issue_date %in% healthdata_hosp_data_daily$issue_date) {
    healthdata_hosp_data_daily <- healthdata_hosp_data_daily %>%
      dplyr::filter(issue_date <= UQ(issue_date))
    
    last_weekly <- healthdata_hosp_data_ts %>%
      dplyr::filter(issue_date <= UQ(issue_date)) %>%
      dplyr::slice_max(issue_date)
    
    last_weekly$issue_date <- issue_date
    last_date <- lubridate::ymd(max(last_weekly$data[[1]]$date))
    max_date <- lubridate::ymd(max(healthdata_hosp_data_daily$date))
    num_dates_to_add <- max_date - last_date

    for (i in seq_len(num_dates_to_add)) {
      new_date <- last_date + i
      if (as.character(new_date) %in% healthdata_hosp_data_daily$date) {
        # if daily data for new_date is available, append it by pulling
        # from the largest issue_date for that day.
        last_weekly$data[[1]] <- dplyr::bind_rows(
          last_weekly$data[[1]],
          healthdata_hosp_data_daily %>%
            dplyr::filter(date == as.character(new_date)) %>%
            dplyr::slice_max(issue_date) %>%
            dplyr::pull(data) %>%
            `[[`(1) %>%
            dplyr::mutate(date = new_date)
        )
      } else {
        required_locations <- unique(last_weekly$data[[1]]$state)
        last_weekly$data[[1]] <- dplyr::bind_rows(
          last_weekly$data[[1]],
          tidyr::expand_grid(
            state = required_locations,
            date = new_date,
            previous_day_admission_adult_covid_confirmed = NA_real_,
            previous_day_admission_pediatric_covid_confirmed = NA_real_
          )
        )
      }
    }

    result <- last_weekly
  } else {
    # neither time series nor daily data were released on this issue date
    result <- NULL
  }

  return(result)
}


#' Preprocess healthdata data set, calculating incidence, adjusting date, and
#' calculating national incidence.
#' 
#' @param raw_healthdata_data tibble one row and columns issue_date and data
#' The data column should be a list of data frames, with column names
#' date, state, previous_day_admission_adult_covid_confirmed, and
#' previous_day_admission_pediatric_covid_confirmed
#' 
#' @return a result of similar format to raw_healthdata_data, but columns
#' date, location, and inc
preprocess_healthdata_data <- function(raw_healthdata_data, fips_codes) {
  result <- raw_healthdata_data

  # calculate incidence column, change date to previous day, and
  # rename state to abbreviation
  result$data[[1]] <- result$data[[1]] %>%
    dplyr::transmute(
      abbreviation = state,
      date = date - 1,
      inc = previous_day_admission_adult_covid_confirmed +
        previous_day_admission_pediatric_covid_confirmed
    )

  # add US location by summing across all others
  result$data[[1]] <- dplyr::bind_rows(
    result$data[[1]],
    result$data[[1]] %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(inc = sum(inc)) %>%
      dplyr::mutate(abbreviation = "US")
  )

  # add location column, remove abbreviation
  result$data[[1]] <- result$data[[1]] %>%
    dplyr::left_join(
      fips_codes %>% dplyr::select(location, abbreviation),
      by = "abbreviation"
    ) %>%
    dplyr::select(-abbreviation)
  
  return(result)
}
