FROM public.ecr.aws/lambda/python:3.11

# Fail fast if we are not on an AL2-style base image with yum
RUN set -eu; \
    if ! command -v yum >/dev/null 2>&1; then \
      echo "ERROR: yum package manager not found. Did you change the base image / Python version away from 3.11 (AL2)?" >&2; \
      echo "Detected OS:" >&2; \
      (cat /etc/os-release || true) >&2; \
      exit 1; \
    fi

# Glue 5.0 alignment
ARG PYSPARK_VERSION=3.5.4

# Iceberg runtime jar for Spark 3.5 + Scala 2.12 and Iceberg 1.7.1
ARG ICEBERG_FRAMEWORK_VERSION=3.5_2.12
ARG ICEBERG_FRAMEWORK_SUB_VERSION=1.7.1

# Optional: align these too (Glue 5.0 OTF library versions)
ARG HUDI_FRAMEWORK_VERSION=0.15.0
ARG DELTA_FRAMEWORK_VERSION=3.3.0

# Build arguments - consolidated at top
ARG HADOOP_VERSION=3.3.4
ARG AWS_SDK_VERSION=1.12.262
ARG FRAMEWORK
ARG DEEQU_FRAMEWORK_VERSION=2.0.3-spark-3.3
ARG AWS_REGION

ENV AWS_REGION=${AWS_REGION}

# System updates and package installation
COPY download_jars.sh /tmp/
RUN set -ex && \
    yum install -y wget unzip java-17-amazon-corretto-headless python3-setuptools && \
    yum clean all && \
    rm -rf /var/cache/yum && \
    pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir setuptools wheel && \
    pip install --no-cache-dir pyspark==$PYSPARK_VERSION boto3 && \
    # Conditional DEEQU installation
    (echo "$FRAMEWORK" | grep -q "DEEQU" && \
     pip install --no-cache-dir --no-deps pydeequ && \
     pip install --no-cache-dir pandas && \
     echo "DEEQU found in FRAMEWORK" || \
     echo "DEEQU not found in FRAMEWORK") && \
    # JAR download and cleanup
    chmod +x /tmp/download_jars.sh && \
    SPARK_HOME="/var/lang/lib/python3.11/site-packages/pyspark" && \
    /tmp/download_jars.sh $FRAMEWORK $SPARK_HOME $HADOOP_VERSION $AWS_SDK_VERSION $DELTA_FRAMEWORK_VERSION $HUDI_FRAMEWORK_VERSION $ICEBERG_FRAMEWORK_VERSION $ICEBERG_FRAMEWORK_SUB_VERSION $DEEQU_FRAMEWORK_VERSION && \
    rm -rf /tmp/* /var/tmp/*

# Copy requirements.txt if present and install
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN if [ -f "${LAMBDA_TASK_ROOT}/requirements.txt" ]; then pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt; fi

# Copy application files
COPY libs/glue_functions /home/glue_functions
COPY spark-class /var/lang/lib/python3.11/site-packages/pyspark/bin/
COPY sparkLambdaHandler.py ${LAMBDA_TASK_ROOT}
# Optionally copy log4j.properties if present
RUN if [ -f log4j.properties ]; then cp log4j.properties /var/lang/lib/python3.11/site-packages/pyspark/conf/; fi

RUN set -ex && \
    yum update -y && \
    yum install -y java-17-amazon-corretto-headless && \
    yum clean all && \
    rm -rf /var/cache/yum /tmp/* /var/tmp/* && \
    chmod -R 755 /home/glue_functions /var/lang/lib/python3.11/site-packages/pyspark && \
    # Diagnostics for spark-class
    ls -la /var/lang/lib/python3.11/site-packages/pyspark/bin/ || echo "Spark bin directory not found" && \
    if [ -f "/var/lang/lib/python3.11/site-packages/pyspark/bin/spark-class" ]; then echo "Custom spark-class after copying:"; cat /var/lang/lib/python3.11/site-packages/pyspark/bin/spark-class; else echo "Custom spark-class not found"; fi && \
    ln -sf /var/lang/lib/python3.11/site-packages/pyspark/bin/spark-class /usr/local/bin/spark-class && \
    ls -la /usr/local/bin/spark-class

ENV SPARK_HOME="/var/lang/lib/python3.11/site-packages/pyspark" \
    SPARK_VERSION="${PYSPARK_VERSION}" \
    JAVA_HOME="/usr/lib/jvm/java-17-amazon-corretto" \
    JAVA_TOOL_OPTIONS="--add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED" \
    PATH="$PATH:/var/lang/lib/python3.11/site-packages/pyspark/bin:/var/lang/lib/python3.11/site-packages/pyspark/sbin:/usr/lib/jvm/java-17-amazon-corretto/bin" \
    PYTHONPATH="/var/lang/lib/python3.11/site-packages/pyspark/python:/var/lang/lib/python3.11/site-packages/pyspark/python/lib/py4j-0.10.9.7-src.zip:/home/glue_functions" \
    INPUT_PATH="" \
    OUTPUT_PATH="" \
    CUSTOM_SQL=""

RUN java -version

RUN chmod 755 ${LAMBDA_TASK_ROOT}/sparkLambdaHandler.py

CMD [ "sparkLambdaHandler.lambda_handler" ]
