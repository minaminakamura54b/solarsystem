# syntax=docker/dockerfile:1
# 解析エンジン（linux/amd64。DJI Thermal SDK が x86_64 Linux 向けのため）
#   docker build --platform linux/amd64 -t solarsystem-analyzer analyzer
#   docker run --rm -v "$PWD/work:/work" solarsystem-analyzer analyze --thermal /work/x.JPG ... --out /work/result.json
# DJI Thermal SDK はイメージに含めない（ライセンス上コミット・配布しない）。
# 使うときは analyzer/bin/ に置いた SDK をマウントし、DJI_IRP_PATH で dji_irp のパスを渡す（Phase S で手順を確定する）。
FROM --platform=linux/amd64 python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /bin/uv

WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PATH="/app/.venv/bin:$PATH"

COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --frozen --no-dev

COPY analyzer ./analyzer

ENTRYPOINT ["python", "-m", "analyzer"]
