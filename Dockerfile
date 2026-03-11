FROM apache/airflow:3.1.7

COPY deps/requirement.txt /opt/airflow/requirement.txt
RUN pip install --no-cache-dir -r /opt/airflow/requirement.txt
