from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo


def local_now(time_zone):
    return datetime.now(ZoneInfo(time_zone))


def utc_for_database(value):
    return value.astimezone(timezone.utc).replace(tzinfo=None)


def local_time_string(value, time_zone):
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(ZoneInfo(time_zone)).isoformat()


def time_string(value):
    if isinstance(value, timedelta):
        total_seconds = int(value.total_seconds()) % (24 * 60 * 60)
        value = time(total_seconds // 3600, (total_seconds % 3600) // 60)
    return value.strftime("%H:%M")
