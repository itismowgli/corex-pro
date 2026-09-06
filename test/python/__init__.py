# Present so `unittest discover -s test/python` can import the start directory.
# Without it Python 3.14 refuses with "Start directory is not importable", while
# 3.12 accepts it, so the suite ran on the target platform and failed for anyone
# on a newer interpreter.
