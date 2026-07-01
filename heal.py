import boto3
import os
import json

def lambda_handler(event, context):
    ssm = boto3.client('ssm')

    instance_id = os.environ.get('INSTANCE_ID')

    if not instance_id:
        return {
            'statusCode': 400,
            'body': json.dumps('Instance ID not found in environment variables')
        }

    print(f"High CPU detected on {instance_id}. Initiating auto-healing...")

    try:
        response = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={'commands': ['killall stress']}
        )
        print("Healing command sent successfully!")

        return {
            'statusCode': 200,
            'body': json.dumps('Auto-healing executed successfully')
        }
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error: {str(e)}")
        }