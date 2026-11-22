import subprocess
import os
import time
import asyncio
import re
from datetime import datetime

from telegram import Bot
from telegram.error import NetworkError, RetryAfter, TimedOut
from telegram.request import HTTPXRequest

# Configuration
SERVER_PREFIX = "SRV_60"  # Change this for different servers
TELEGRAM_TOKEN = "7901269226:AAH9vxO5N3Se8238TQKv6tyV_eA9xRHSIWI"
TELEGRAM_CHAT_ID = -1001818294186

# python-telegram-bot 22.x defaults are too short (connect/read/write=5s, media=20s).
# Slow Telegram API responses then raise telegram.error.TimedOut even after the .ovpn is created.
TELEGRAM_REQUEST = HTTPXRequest(
    connect_timeout=30.0,
    read_timeout=60.0,
    write_timeout=60.0,
    pool_timeout=10.0,
    media_write_timeout=120.0,
)

UPLOAD_RETRIES = 5
# Groups/supergroups are limited to about 20 bot messages per minute.
# Stay below that so Telegram does not silently drop or 429 a long batch.
UPLOAD_GAP_SECONDS = 4.0
BATCH_EVERY = 15
BATCH_PAUSE_SECONDS = 30.0


class UploadPacer:
    """Space out Telegram uploads so a long run does not hit flood limits."""

    def __init__(self):
        self.sent = 0
        self.last_send = 0.0

    async def wait_before_send(self):
        if self.last_send:
            remain = UPLOAD_GAP_SECONDS - (time.monotonic() - self.last_send)
            if remain > 0:
                print(f"Waiting {remain:.1f}s before next Telegram upload...")
                await asyncio.sleep(remain)
        if self.sent > 0 and self.sent % BATCH_EVERY == 0:
            print(
                f"Pausing {BATCH_PAUSE_SECONDS:.0f}s after {self.sent} uploads "
                "to stay under Telegram's ~20 messages/minute group limit..."
            )
            await asyncio.sleep(BATCH_PAUSE_SECONDS)

    def mark_sent(self):
        self.sent += 1
        self.last_send = time.monotonic()


def ask_continue_after_upload_failure(client_name, file_path):
    print(
        f"\nUpload failed after {UPLOAD_RETRIES} attempts for {client_name}.\n"
        f"The .ovpn is on disk: {file_path}\n"
        "ادامه بدم ساخت و آپلود بقیه فایل‌ها؟\n"
        "y = ادامه  |  n = توقف کل فرایند"
    )
    while True:
        answer = input("Continue? [y/n]: ").strip().lower()
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print("Please enter y or n.")


async def send_to_telegram(bot, file_path, client_name, pacer, retries=UPLOAD_RETRIES):
    last_error = None
    await pacer.wait_before_send()
    for attempt in range(1, retries + 1):
        try:
            with open(file_path, "rb") as file:
                await bot.send_document(
                    chat_id=TELEGRAM_CHAT_ID,
                    document=file,
                    filename=os.path.basename(file_path),
                    connect_timeout=30.0,
                    read_timeout=60.0,
                    write_timeout=120.0,
                    pool_timeout=10.0,
                )
            pacer.mark_sent()
            print(f"File {file_path} sent to Telegram for {client_name}")
            return True
        except RetryAfter as e:
            last_error = e
            wait_s = int(getattr(e, "retry_after", 5)) + 1
            print(
                f"Telegram flood wait {wait_s}s for {client_name} "
                f"(attempt {attempt}/{retries})"
            )
            await asyncio.sleep(wait_s)
        except (TimedOut, NetworkError) as e:
            last_error = e
            wait_s = min(40, 5 * attempt)
            print(
                f"Telegram {type(e).__name__} for {client_name} "
                f"(attempt {attempt}/{retries}): {e}"
            )
            if attempt < retries:
                await asyncio.sleep(wait_s)
        except Exception as e:
            last_error = e
            print(f"Error sending {file_path} to Telegram: {e}")
            if attempt < retries:
                await asyncio.sleep(min(40, 5 * attempt))
            else:
                break
    print(f"Giving up sending {file_path} for {client_name}: {last_error}")
    return False

def run_openvpn_script(client_name):
    env = os.environ.copy()
    env["MENU_OPTION"] = "1"
    env["PASS"] = "1"
    env["CLIENT"] = client_name
    try:
        result = subprocess.run(["./openvpn-install.sh"], env=env, capture_output=True, text=True)
        print(f"Output for {client_name}:\n{result.stdout}")
        if result.stderr:
            print(f"Errors for {client_name}:\n{result.stderr}")
        return result.returncode == 0
    except Exception as e:
        print(f"Error running openvpn-install.sh for {client_name}: {e}")
        return False

def get_jalali_date_str():
    """Convert Unix timestamp to Jalali date string (YYYY-MM-DD)."""
    from jdatetime import datetime as jdatetime
    unix_time=time.time()
    gregorian_date = time.gmtime(unix_time + 2592000)
    jalali_date = jdatetime.fromgregorian(
        year=gregorian_date.tm_year,
        month=gregorian_date.tm_mon,
        day=gregorian_date.tm_mday,
    )
    return jalali_date.strftime("%Y-%m-%d")

async def main():
    try:
        num_clients = int(input("Enter the number of clients to generate: "))
        if num_clients <= 0:
            raise ValueError("Number of clients must be positive")
        date = input(f"Enter the date (format: YYYY-MM-DD, e.g., {get_jalali_date_str()}): ")
        datetime.strptime(date, "%Y-%m-%d")  # Validate date format
    except ValueError as e:
        print(f"Invalid input: {e}")
        return

    if not os.path.isfile("openvpn-install.sh") or not os.access("openvpn-install.sh", os.X_OK):
        print("Error: openvpn-install.sh not found or not executable")
        return

    # Check for existing clients in index.txt
    try:
        with open("/etc/openvpn/easy-rsa/pki/index.txt", "r") as file:
            clients = [line for line in file if line.startswith("V")]
        number_of_clients = len(clients)
        if number_of_clients == 0:
            print("You have no existing clients!")
            start_index = 101  # Default start index
        else:
            # Get the last client's name
            last_client = clients[-1].split("/")[-1].strip()
            print(f"Last client: {last_client}")

            # Extract the 3-digit client code after SERVER_PREFIX (e.g., SRV_20123 or LTA_10123)
            match_pattern = f"{SERVER_PREFIX}(\\d{{3}})"
            match = re.search(match_pattern, last_client)
            if match:
                client_code = int(match.group(1))  # e.g., 123
                if client_code > 950:  # If client code exceeds 950, reset to 101
                    print(f"Last client code ({client_code}) exceeds 950. Resetting to 101.")
                    start_index = 101
                else:
                    start_index = client_code + 1  # Next client code (e.g., 124)
            else:
                print(f"Invalid client name format in {last_client}. Expected '{SERVER_PREFIX}XXX'")
                start_index = int(input("Enter the 3-digit client code to start (e.g., 101): "))
    except FileNotFoundError:
        print("Error: /etc/openvpn/easy-rsa/pki/index.txt not found")
        start_index = 101  # Default start index
    except Exception as e:
        print(f"Error reading index.txt: {e}")
        start_index = int(input("Enter the 3-digit client code to start (e.g., 101): "))

    # Ensure start_index is a valid 3-digit number
    try:
        if start_index < 100 or start_index > 999:
            print("Start index must be a 3-digit number (100-999).")
            start_index = int(input("Enter the 3-digit client code to start (e.g., 101): "))
    except ValueError:
        print("Invalid input for start index.")
        return

    # Generate clients
    pacer = UploadPacer()
    async with Bot(token=TELEGRAM_TOKEN, request=TELEGRAM_REQUEST) as bot:
        for i in range(start_index, start_index + num_clients):
            # Reset to 101 if client code exceeds 950
            client_code = i if i <= 950 else 101 + (i - start_index)
            client_name = f"{SERVER_PREFIX}{str(client_code).zfill(3)}_{date}"
            print(f"Generating client: {client_name}")
            await asyncio.sleep(1)
            success = run_openvpn_script(client_name)
            if not success:
                print(f"Failed to generate client: {client_name}")
                continue

            file_path = f"{client_name}.ovpn"
            if not os.path.exists(file_path):
                print(f"File {file_path} not found for {client_name}")
                continue

            uploaded = await send_to_telegram(bot, file_path, client_name, pacer)
            if uploaded:
                continue
            if not ask_continue_after_upload_failure(client_name, file_path):
                print("Stopping the whole process.")
                return
            print("Continuing with the next clients. Failed file stays on disk.")

if __name__ == "__main__":
    asyncio.run(main())
