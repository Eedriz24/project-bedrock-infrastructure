"""
bedrock-asset-processor
Triggered by S3 ObjectCreated events on the bedrock-assets-<student-id>
bucket. Logs the uploaded filename to CloudWatch Logs.
"""

def handler(event, context):
    for record in event.get("Records", []):
        key = record["s3"]["object"]["key"]
        print(f"Image received: {key}")
    return {"statusCode": 200}
