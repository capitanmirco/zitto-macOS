"""Entry point: command line with arguments, window without."""

import sys


def main() -> int:
    if len(sys.argv) > 1:
        from .cli import main as run
    else:
        from .gui import main as run
    return run()


if __name__ == "__main__":
    sys.exit(main())
