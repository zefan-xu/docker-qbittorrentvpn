FROM python:3.15-alpine@sha256:a58bff94159509f3a3f774da8c244001b74e0348139c421956abf991bfc9f1b8

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
