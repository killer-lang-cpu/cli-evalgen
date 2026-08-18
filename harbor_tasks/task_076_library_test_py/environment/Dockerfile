FROM python:3.11-slim

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir pytest

WORKDIR /workspace

# Copy codebase with the injected bug
COPY . /workspace/

CMD ["/bin/bash"]
