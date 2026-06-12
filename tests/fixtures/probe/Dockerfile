FROM python:3.14-alpine@sha256:003970a263347645cd23d4f90929ad16ba7ce7d808ee4674ffcc93cb21cc289f

WORKDIR /app
COPY probe.py /app/probe.py

EXPOSE 53/udp 8080/tcp
ENTRYPOINT ["python", "/app/probe.py"]
