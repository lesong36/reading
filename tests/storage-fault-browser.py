"""Compatibility entrypoint for the expanded storage fault regression suite."""
import runpy
from pathlib import Path
runpy.run_path(str(Path(__file__).with_name('storage-management-browser.py')), run_name='__main__')
