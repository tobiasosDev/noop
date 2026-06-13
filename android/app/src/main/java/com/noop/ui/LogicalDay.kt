package com.noop.ui

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * The "logical day" key the dashboard treats as Today.
 *
 * A naive `LocalDate.now()` rolls the moment the clock passes midnight, so between 00:00 and the
 * morning the dashboard would look up a brand-new calendar day that has no banked row yet and blank
 * out — even though the user is still in the same wear/sleep cycle as the previous evening (#144).
 *
 * The logical day rolls at [rolloverHour] (04:00 LOCAL) instead: it is the calendar date of
 * `now - rolloverHour hours`, so the small hours after midnight still resolve to the PRIOR calendar
 * date's row. This is a PRESENTATION-layer remap only — used purely to pick which stored row is
 * "Today" and to anchor the Today HR-trend window. Stored row keys are never rewritten (they stay
 * keyed on their own true calendar date), so the blast radius is deliberately tiny. An explicit
 * date label stays visible under the header so the remap is always honest.
 *
 * Pure + injectable so [LogicalDayTest] can pin the boundaries:
 *  - 23:59 → same calendar day (still the evening's logical day)
 *  - 01:00 → previous calendar day (the night still belongs to yesterday)
 *  - 04:01 → the new calendar day (a fresh logical day has begun)
 */
internal fun logicalDay(
    now: ZonedDateTime,
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): LocalDate = now.minusHours(rolloverHour.toLong()).toLocalDate()

/** Convenience overload for the live call sites: the logical day for the current instant in [zone]. */
internal fun logicalDayNow(
    zone: ZoneId = ZoneId.systemDefault(),
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): LocalDate = logicalDay(ZonedDateTime.now(zone), rolloverHour)

/** ISO `yyyy-MM-dd` key for the current logical day — matches how [DailyMetric.day] is stored. */
internal fun logicalDayKeyNow(
    zone: ZoneId = ZoneId.systemDefault(),
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): String = logicalDayNow(zone, rolloverHour).toString()

/**
 * Start-of-logical-day as an epoch second in [zone] — the anchor for the Today HR-trend window so it
 * spans from the logical day's 00:00 (its real calendar midnight) rather than restarting at the new
 * calendar midnight while we're still showing yesterday's logical day in the small hours. (#144)
 */
internal fun logicalDayStartEpochSecond(
    now: ZonedDateTime,
    zone: ZoneId = now.zone,
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): Long = logicalDay(now, rolloverHour).atStartOfDay(zone).toEpochSecond()

/** 04:00 local — the hour the logical day rolls. Between midnight and this hour, Today stays put. */
internal const val LOGICAL_DAY_ROLLOVER_HOUR: Int = 4

/** Exposed for symmetry / call-site readability (start of the rollover window). */
internal val LOGICAL_DAY_ROLLOVER_TIME: LocalTime = LocalTime.of(LOGICAL_DAY_ROLLOVER_HOUR, 0)
