# Python 3.14.9 / Alpine 3.24 multi-platform index, including linux/arm64.
FROM docker.io/library/python:3.14.9-alpine3.24@sha256:dbeb11d16bb95c3a7e3c25c842cb9f20cbc8c18f8be0461a4a0dcc861ad386a0

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
# Precompile stdlib and dependencies so request children need no runtime bytecode writes.
RUN python -m pip install --no-cache-dir --only-binary=:all: --require-hashes -r requirements.txt \
    && python -m compileall -q /usr/local/lib/python3.14
COPY collector.py transport.py ./
EXPOSE 9126
CMD ["python", "collector.py"]
