FROM python:3.13-slim
WORKDIR /srv/hy2
COPY worker/requirements.txt worker/requirements.txt
RUN pip install --no-cache-dir -r worker/requirements.txt && useradd --system --uid 10001 hy2 && mkdir /data && chown hy2 /data
COPY hysteria.sh hysteria.sh
COPY worker/service.py worker/remote.py worker/subscription.py worker/
USER hy2
WORKDIR /srv/hy2/worker
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["gunicorn","--workers","1","--threads","4","--bind","0.0.0.0:8080","service:production()"]
