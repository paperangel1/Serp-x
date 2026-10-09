"""Sunrise / sunset from latitude and longitude (the sunrise equation, ±2 min), no network and no dependencies."""
import math
from datetime import datetime, timedelta, timezone

J2000 = 2451545.0
UNIX_JD = 2440587.5


def _jd_to_utc(jd):
    return datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(days=jd - UNIX_JD)


def sun_times(lat, lon_east, utc_day):
    """(sunrise, sunset) as aware UTC datetimes of the solar day that starts near `utc_day` (a date),
    or None in polar day / polar night."""
    jd_day = utc_day.toordinal() - 719163 + UNIX_JD       # midnight UTC of that date
    n = math.ceil(jd_day - J2000 + 0.0008)
    j_star = n - lon_east / 360.0                           # east longitude positive
    m = (357.5291 + 0.98560028 * j_star) % 360.0
    mr = math.radians(m)
    c = 1.9148 * math.sin(mr) + 0.0200 * math.sin(2 * mr) + 0.0003 * math.sin(3 * mr)
    lam = math.radians((m + c + 180.0 + 102.9372) % 360.0)
    j_transit = J2000 + j_star + 0.0053 * math.sin(mr) - 0.0069 * math.sin(2 * lam)
    sin_dec = math.sin(lam) * math.sin(math.radians(23.4397))
    cos_dec = math.sqrt(max(0.0, 1.0 - sin_dec * sin_dec))
    phi = math.radians(lat)
    cos_w = (math.sin(math.radians(-0.833)) - math.sin(phi) * sin_dec) / (math.cos(phi) * cos_dec)
    if cos_w < -1.0 or cos_w > 1.0:
        return None
    w = math.degrees(math.acos(cos_w))
    return _jd_to_utc(j_transit - w / 360.0), _jd_to_utc(j_transit + w / 360.0)


def next_sun_event(now_ts, kind, offset_min, lat, lon_east):
    """Unix time of the next sunrise/sunset (+ offset minutes) strictly after now_ts, or None when the sun never
    rises / sets in the next days (polar)."""
    now = datetime.fromtimestamp(now_ts, timezone.utc)
    best = None
    for delta in range(-2, 5):
        t = sun_times(lat, lon_east, (now + timedelta(days=delta)).date())
        if t is None:
            continue
        ts = (t[0] if kind == "sunrise" else t[1]).timestamp() + offset_min * 60.0
        if ts > now_ts and (best is None or ts < best):
            best = ts
    return best
