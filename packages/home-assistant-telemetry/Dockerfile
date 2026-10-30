# Python 3.15.2 / Alpine 3.24 multi-platform index, including linux/arm64.
FROM docker.io/library/python:3.15.2-alpine3.24@sha256:20a82dbc2783112ddb91d1534603f802d222a3e63e593cd002eb2ac534e70211

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
# Precompile stdlib and dependencies so request children need no runtime bytecode writes.
RUN python -m pip install --no-cache-dir --only-binary=:all: --require-hashes -r requirements.txt \
    && python -m compileall -q /usr/local/lib/python3.15
COPY collector.py transport.py ./
EXPOSE 9126
CMD ["python", "collector.py"]
