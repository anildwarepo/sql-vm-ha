"""Next-occurrence math for Azure Maintenance Configuration schedules.

Supports the recurEvery formats used by Azure Update Manager:
  Day | 3Days
  Week | 2Weeks Saturday,Sunday
  Month day23,day-1
  Month Second Saturday | Month Last Sunday Offset-3
"""

from __future__ import annotations

import calendar
import re
from datetime import date, datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

# Windows time zone ids used by maintenance configurations -> IANA.
WINDOWS_TZ = {
    "utc": "UTC",
    "coordinated universal time": "UTC",
    "pacific standard time": "America/Los_Angeles",
    "mountain standard time": "America/Denver",
    "us mountain standard time": "America/Phoenix",
    "central standard time": "America/Chicago",
    "eastern standard time": "America/New_York",
    "atlantic standard time": "America/Halifax",
    "alaskan standard time": "America/Anchorage",
    "hawaiian standard time": "Pacific/Honolulu",
    "gmt standard time": "Europe/London",
    "w. europe standard time": "Europe/Berlin",
    "central europe standard time": "Europe/Budapest",
    "romance standard time": "Europe/Paris",
    "india standard time": "Asia/Kolkata",
    "singapore standard time": "Asia/Singapore",
    "tokyo standard time": "Asia/Tokyo",
    "china standard time": "Asia/Shanghai",
    "aus eastern standard time": "Australia/Sydney",
    "e. australia standard time": "Australia/Brisbane",
}

WEEKDAYS = {name.lower(): i for i, name in enumerate(calendar.day_name)}
ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1}


def resolve_tz(name: str | None) -> ZoneInfo:
    if not name:
        return ZoneInfo("UTC")
    key = name.strip().lower()
    try:
        return ZoneInfo(WINDOWS_TZ.get(key, name))
    except Exception:  # unknown zone id
        return ZoneInfo("UTC")


def parse_duration(text: str | None) -> timedelta:
    if not text:
        return timedelta(hours=2)
    m = re.match(r"^(\d+):(\d{2})$", text.strip())
    if m:
        return timedelta(hours=int(m.group(1)), minutes=int(m.group(2)))
    m = re.match(r"^PT(?:(\d+)H)?(?:(\d+)M)?$", text.strip(), re.I)
    if m:
        return timedelta(hours=int(m.group(1) or 0), minutes=int(m.group(2) or 0))
    return timedelta(hours=2)


def _nth_weekday(year: int, month: int, weekday: int, ordinal: int) -> date:
    if ordinal == -1:
        last = calendar.monthrange(year, month)[1]
        d = date(year, month, last)
        return d - timedelta(days=(d.weekday() - weekday) % 7)
    d = date(year, month, 1)
    d += timedelta(days=(weekday - d.weekday()) % 7)
    return d + timedelta(weeks=ordinal - 1)


class Recurrence:
    def __init__(self, recur_every: str, start: date):
        self.raw = recur_every or ""
        self.start = start
        tokens = self.raw.replace(",", " , ").split()
        head = tokens[0] if tokens else "Day"
        m = re.match(r"^(\d*)\s*(Day|Days|Week|Weeks|Month|Months)$", head, re.I)
        if not m:
            raise ValueError(f"Unsupported recurEvery '{self.raw}'")
        self.interval = int(m.group(1) or 1)
        self.unit = m.group(2).lower().rstrip("s")
        rest = [t for t in tokens[1:] if t != ","]
        self.weekdays: set[int] = set()
        self.month_days: list[int] = []
        self.ordinal: int | None = None
        self.ord_weekday: int | None = None
        self.offset = 0
        if self.unit == "week":
            self.weekdays = {WEEKDAYS[t.lower()] for t in rest if t.lower() in WEEKDAYS} or {start.weekday()}
        elif self.unit == "month":
            for t in rest:
                tl = t.lower()
                if tl.startswith("day"):
                    self.month_days.append(int(tl[3:]))
                elif tl in ORDINALS:
                    self.ordinal = ORDINALS[tl]
                elif tl in WEEKDAYS:
                    self.ord_weekday = WEEKDAYS[tl]
                elif tl.startswith("offset"):
                    self.offset = int(tl[6:])
            if not self.month_days and self.ordinal is None:
                self.month_days = [start.day]

    def matches(self, d: date) -> bool:
        if d < self.start:
            return False
        if self.unit == "day":
            return (d - self.start).days % self.interval == 0
        if self.unit == "week":
            start_monday = self.start - timedelta(days=self.start.weekday())
            weeks = (d - start_monday).days // 7
            return weeks % self.interval == 0 and d.weekday() in self.weekdays
        months = (d.year - self.start.year) * 12 + d.month - self.start.month
        if self.ordinal is not None and self.ord_weekday is not None:
            # The offset can move the day into the neighbouring month, so test this month and its neighbours.
            for delta in (-1, 0, 1):
                y, mth = d.year, d.month + delta
                if mth < 1:
                    y, mth = y - 1, 12
                elif mth > 12:
                    y, mth = y + 1, 1
                base_months = (y - self.start.year) * 12 + mth - self.start.month
                if base_months < 0 or base_months % self.interval:
                    continue
                if _nth_weekday(y, mth, self.ord_weekday, self.ordinal) + timedelta(days=self.offset) == d:
                    return True
            return False
        if months % self.interval:
            return False
        last = calendar.monthrange(d.year, d.month)[1]
        for md in self.month_days:
            target = last + md + 1 if md < 0 else md
            if target == d.day:
                return True
        return False


def next_windows(
    start_date_time: str,
    recur_every: str,
    duration: str | None,
    time_zone: str | None,
    count: int = 4,
    now: datetime | None = None,
    expiration: str | None = None,
) -> list[dict[str, Any]]:
    """Return the current/next `count` windows as ISO strings (local and UTC)."""
    tz = resolve_tz(time_zone)
    start_local = datetime.strptime(start_date_time.strip()[:16], "%Y-%m-%d %H:%M").replace(tzinfo=tz)
    length = parse_duration(duration)
    expires = None
    if expiration:
        try:
            expires = datetime.strptime(expiration.strip()[:16], "%Y-%m-%d %H:%M").replace(tzinfo=tz)
        except ValueError:
            expires = None
    rule = Recurrence(recur_every, start_local.date())
    now = (now or datetime.now(timezone.utc)).astimezone(tz)
    day = max(start_local.date(), (now - length).date())
    out: list[dict[str, Any]] = []
    for _ in range(800):
        if rule.matches(day):
            begin = datetime.combine(day, start_local.timetz()).replace(tzinfo=tz)
            end = begin + length
            if expires and begin > expires:
                break
            if end > now:
                out.append(
                    {
                        "start_local": begin.isoformat(),
                        "end_local": end.isoformat(),
                        "start_utc": begin.astimezone(timezone.utc).isoformat(),
                        "end_utc": end.astimezone(timezone.utc).isoformat(),
                        "in_progress": begin <= now < end,
                    }
                )
                if len(out) >= count:
                    break
        day += timedelta(days=1)
    return out
