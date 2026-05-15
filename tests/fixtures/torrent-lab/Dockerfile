FROM python:3.14-alpine@sha256:5a824eb82cc75361f98611f3cfc5091ea33f10a6ccea4d4ebdabbc523b9a1614

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
