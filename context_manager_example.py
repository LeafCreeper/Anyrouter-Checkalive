"""
Python Context Manager Pattern Examples
========================================
Two common ways to implement context managers:
  1. Class-based (__enter__ / __exit__)
  2. Generator-based (using @contextmanager decorator from contextlib)
"""

import time
from contextlib import contextmanager


# ─── CLASS-BASED CONTEXT MANAGER ───────────────────────────────────────────

class Timer:
    """Measures how long a block of code takes to execute."""

    def __enter__(self):
        print("⏱ Timer started...")
        self.start = time.perf_counter()
        return self  # returned value is bound to 'as' variable

    def __exit__(self, exc_type, exc_val, exc_tb):
        elapsed = time.perf_counter() - self.start
        print(f"⌛ Elapsed: {elapsed:.4f}s")
        # Return False (or None) to propagate any exception.
        # Return True to suppress the exception.
        return False


# ─── GENERATOR-BASED CONTEXT MANAGER (simpler for many cases) ──────────────

@contextmanager
def managed_file(filename: str, mode: str = "r"):
    """Safely open and close a file using the contextmanager decorator."""
    print(f"📂 Opening {filename!r}")
    f = open(filename, mode)
    try:
        yield f                # <-- the code in the 'with' block runs here
    finally:
        print(f"📂 Closing {filename!r}")
        f.close()


# ─── USAGE ──────────────────────────────────────────────────────────────────

def main():
    # 1️⃣ Class-based: timing a block of code
    print("=== Class-based context manager ===")
    with Timer() as t:
        total = sum(range(1_000_000))
        print(f"Sum calculated = {total}")
    # Timer.__exit__ runs here automatically

    print()

    # 2️⃣ Generator-based: automatic file close
    print("=== Generator-based context manager ===")
    with managed_file("context_manager_example.py", "r") as f:
        first_line = f.readline().strip()
        print(f"First line of this file: {first_line}")
    # file is guaranteed to be closed here, even if an exception occurred


if __name__ == "__main__":
    main()

