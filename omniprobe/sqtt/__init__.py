"""Hardware counters per source line from SQTT site markers and SPM.

counter_fit.py lines up thread-trace site markers (which source line ran when)
with SPM counter samples from the same rocprofv3 run and fits each counter to
the source lines with least squares. See docs/sqtt-spm-attribution.md.
"""
