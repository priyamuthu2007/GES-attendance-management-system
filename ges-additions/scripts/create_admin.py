"""Create an admin dashboard user.  Run from the project root:  python scripts/create_admin.py alice"""
import getpass
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

from attendance.admin import create_admin  # noqa: E402

if len(sys.argv) != 2:
    sys.exit("usage: python scripts/create_admin.py <username>")
pw = getpass.getpass("Password (min 12 characters): ")
if len(pw) < 12 or pw != getpass.getpass("Repeat password: "):
    sys.exit("Passwords must match and be at least 12 characters.")
create_admin(sys.argv[1], pw)
print("Admin created. Sign in at /admin/login")
