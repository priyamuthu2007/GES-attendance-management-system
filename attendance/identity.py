import re


EMAIL_PATTERN = re.compile(
    r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,63}\Z"
)


def normalize_email(value):
    if not isinstance(value, str):
        raise ValueError("Enter a valid email address.")
    email = value.strip().lower()
    local_part = email.split("@", 1)[0]
    if (
        len(email) > 254
        or len(local_part) > 64
        or not EMAIL_PATTERN.fullmatch(email)
        or ".." in local_part
        or local_part.startswith(".")
        or local_part.endswith(".")
    ):
        raise ValueError("Enter a valid email address.")
    return email
