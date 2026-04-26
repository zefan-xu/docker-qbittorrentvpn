FROM python:3.12-alpine

WORKDIR /app
COPY probe.py /app/probe.py

EXPOSE 53/udp 8080/tcp
ENTRYPOINT ["python", "/app/probe.py"]
