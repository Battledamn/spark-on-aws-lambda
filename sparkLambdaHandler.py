import boto3
import sys
import os
import subprocess
import logging
import json

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
handler.setFormatter(formatter)
logger.addHandler(handler)

def s3_script_download(s3_bucket_script: str,input_script: str)-> None:
    """
    """
    s3_client = boto3.resource("s3")

    try:
        logger.info(f'Now downloading script {input_script} in {s3_bucket_script} to /tmp')
        s3_client.Bucket(s3_bucket_script).download_file(input_script, "/tmp/spark_script.py")
      
    except Exception as e :
        logger.error(f'Error downloading the script {input_script} in {s3_bucket_script}: {e}')
    else:
        logger.info(f'Script {input_script} successfully downloaded to /tmp')


def spark_submit(s3_bucket_script: str, input_script: str, event: dict) -> None:
    """
    Submits a local Spark script using spark-submit.
    """

    java17_shim = (
        "--add-exports=java.base/sun.nio.ch=ALL-UNNAMED "
        "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED "
        "--add-opens=java.base/java.nio=ALL-UNNAMED"
    )

    # 1) Export shim via env as well (catches any Java subprocesses, including launcher oddities)
    # Append (don't overwrite) in case you already set these in the Dockerfile.
    os.environ["JAVA_TOOL_OPTIONS"] = (os.environ.get("JAVA_TOOL_OPTIONS", "") + " " + java17_shim).strip()
    os.environ["_JAVA_OPTIONS"] = (os.environ.get("_JAVA_OPTIONS", "") + " " + java17_shim).strip()

    # 2) Copy event into env safely (stringify), but do NOT allow overwriting the Java option envs
    for key, value in event.items():
        if key in ("JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS"):
            continue
        os.environ[str(key)] = str(value)

    cmd = [
        "spark-submit",

        # Driver JVM (launcher-level)
        "--driver-java-options", java17_shim,

        # Driver JVM (SparkConf-level)
        "--conf", f"spark.driver.extraJavaOptions={java17_shim}",

        # Executor JVM (SparkConf-level)
        "--conf", f"spark.executor.extraJavaOptions={java17_shim}",

        "/tmp/spark_script.py",
        "--event", json.dumps(event),
    ]

    try:
        logger.info(f"Spark-Submitting the Spark script {input_script} from {s3_bucket_script}")
        logger.info("spark-submit cmd: %s", " ".join(cmd))
        logger.info("JAVA_TOOL_OPTIONS=%s", os.environ.get("JAVA_TOOL_OPTIONS", ""))
        subprocess.run(cmd, check=True, env=os.environ)
    except Exception as e:
        logger.error(f"Error Spark-Submit with exception: {e}")
        raise
    else:
        logger.info(f"Script {input_script} successfully submitted")


def lambda_handler(event, context):

    """
    Lambda_handler is called when the AWS Lambda
    is triggered. The function is downloading file 
    from Amazon S3 location and spark submitting 
    the script in AWS Lambda
    """

    logger.info("******************Start AWS Lambda Handler************")
    s3_bucket_script = os.environ['SCRIPT_BUCKET']
    input_script = os.environ['SPARK_SCRIPT']
    os.environ['INPUT_PATH'] = event.get('INPUT_PATH','')
    os.environ['OUTPUT_PATH'] = event.get('OUTPUT_PATH', '')

    s3_script_download(s3_bucket_script,input_script)
    
    # Set the environment variables for the Spark application
    spark_submit(s3_bucket_script,input_script, event)
   
