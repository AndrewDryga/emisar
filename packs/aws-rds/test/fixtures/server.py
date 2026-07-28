from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

CANARY = "packtest-canary-aws-rds-value-918d"
NS = "http://rds.amazonaws.com/doc/2014-10-31/"


def wrap(action, result):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<{action}Response xmlns="{NS}">
  <{action}Result>{result}</{action}Result>
  <ResponseMetadata><RequestId>packtest-request</RequestId></ResponseMetadata>
</{action}Response>"""


INSTANCE = f"""
<DBInstance>
  <DBInstanceIdentifier>harness-db</DBInstanceIdentifier>
  <DBInstanceClass>db.t3.micro</DBInstanceClass>
  <Engine>postgres</Engine>
  <EngineVersion>15.7</EngineVersion>
  <DBInstanceStatus>available</DBInstanceStatus>
  <MasterUsername>{CANARY}</MasterUsername>
  <AvailabilityZone>us-east-1a</AvailabilityZone>
  <MultiAZ>false</MultiAZ>
  <PubliclyAccessible>false</PubliclyAccessible>
  <StorageType>gp3</StorageType>
  <AllocatedStorage>20</AllocatedStorage>
  <MaxAllocatedStorage>100</MaxAllocatedStorage>
  <StorageEncrypted>true</StorageEncrypted>
  <KmsKeyId>arn:aws:kms:us-east-1:123456789012:key/harness</KmsKeyId>
  <BackupRetentionPeriod>7</BackupRetentionPeriod>
  <PreferredBackupWindow>03:00-04:00</PreferredBackupWindow>
  <PreferredMaintenanceWindow>sun:05:00-sun:06:00</PreferredMaintenanceWindow>
  <AutoMinorVersionUpgrade>true</AutoMinorVersionUpgrade>
  <DeletionProtection>true</DeletionProtection>
  <IAMDatabaseAuthenticationEnabled>true</IAMDatabaseAuthenticationEnabled>
  <Endpoint>
    <Address>harness-db.example.test</Address><Port>5432</Port>
    <HostedZoneId>Z1HARNESS</HostedZoneId>
  </Endpoint>
  <VpcSecurityGroups>
    <VpcSecurityGroupMembership>
      <VpcSecurityGroupId>sg-0123456789abcdef0</VpcSecurityGroupId>
      <Status>active</Status>
    </VpcSecurityGroupMembership>
  </VpcSecurityGroups>
  <DBParameterGroups>
    <DBParameterGroup>
      <DBParameterGroupName>harness-parameters</DBParameterGroupName>
      <ParameterApplyStatus>in-sync</ParameterApplyStatus>
    </DBParameterGroup>
  </DBParameterGroups>
  <PendingModifiedValues><AllocatedStorage>30</AllocatedStorage></PendingModifiedValues>
  <TagList><Tag><Key>secret</Key><Value>{CANARY}</Value></Tag></TagList>
</DBInstance>
"""

CLUSTER = f"""
<DBCluster>
  <DBClusterIdentifier>harness-cluster</DBClusterIdentifier>
  <Engine>aurora-postgresql</Engine>
  <EngineMode>provisioned</EngineMode>
  <EngineVersion>15.4</EngineVersion>
  <Status>available</Status>
  <MasterUsername>{CANARY}</MasterUsername>
  <AvailabilityZones><AvailabilityZone>us-east-1a</AvailabilityZone><AvailabilityZone>us-east-1b</AvailabilityZone></AvailabilityZones>
  <MultiAZ>true</MultiAZ>
  <Endpoint>harness-cluster.example.test</Endpoint>
  <ReaderEndpoint>harness-cluster-ro.example.test</ReaderEndpoint>
  <Port>5432</Port>
  <DBClusterArn>arn:aws:rds:us-east-1:123456789012:cluster:harness-cluster</DBClusterArn>
  <DBClusterResourceId>cluster-HARNESS</DBClusterResourceId>
  <DBSubnetGroup>harness-subnets</DBSubnetGroup>
  <BackupRetentionPeriod>7</BackupRetentionPeriod>
  <PreferredBackupWindow>03:00-04:00</PreferredBackupWindow>
  <PreferredMaintenanceWindow>sun:05:00-sun:06:00</PreferredMaintenanceWindow>
  <StorageEncrypted>true</StorageEncrypted>
  <IAMDatabaseAuthenticationEnabled>true</IAMDatabaseAuthenticationEnabled>
  <DeletionProtection>true</DeletionProtection>
  <DBClusterMembers>
    <DBClusterMember>
      <DBInstanceIdentifier>harness-db</DBInstanceIdentifier>
      <IsClusterWriter>true</IsClusterWriter>
      <DBClusterParameterGroupStatus>in-sync</DBClusterParameterGroupStatus>
      <PromotionTier>1</PromotionTier>
    </DBClusterMember>
  </DBClusterMembers>
  <PendingModifiedValues><EngineVersion>15.5</EngineVersion></PendingModifiedValues>
  <TagList><Tag><Key>secret</Key><Value>{CANARY}</Value></Tag></TagList>
</DBCluster>
"""


def response(action, params):
    if action == "DescribeDBInstances":
        if params.get("DBInstanceIdentifier", ["harness-db"])[0] != "harness-db":
            return None
        return wrap(action, f"<DBInstances>{INSTANCE}</DBInstances>")
    if action == "DescribeDBClusters":
        if params.get("DBClusterIdentifier", ["harness-cluster"])[0] != "harness-cluster":
            return None
        return wrap(action, f"<DBClusters>{CLUSTER}</DBClusters>")
    if action == "DescribeDBSnapshots":
        snapshot = """
<DBSnapshot>
  <DBSnapshotIdentifier>harness-snapshot</DBSnapshotIdentifier>
  <DBInstanceIdentifier>harness-db</DBInstanceIdentifier>
  <SnapshotCreateTime>2026-07-27T12:00:00Z</SnapshotCreateTime>
  <Engine>postgres</Engine><EngineVersion>15.7</EngineVersion>
  <Status>available</Status><AllocatedStorage>20</AllocatedStorage>
  <AvailabilityZone>us-east-1a</AvailabilityZone><Port>5432</Port>
  <MasterUsername>harness</MasterUsername><SnapshotType>manual</SnapshotType>
  <PercentProgress>100</PercentProgress><Encrypted>true</Encrypted>
</DBSnapshot>"""
        return wrap(action, f"<DBSnapshots>{snapshot}</DBSnapshots>")
    if action == "DescribeDBClusterSnapshots":
        snapshot = """
<DBClusterSnapshot>
  <DBClusterSnapshotIdentifier>harness-cluster-snapshot</DBClusterSnapshotIdentifier>
  <DBClusterIdentifier>harness-cluster</DBClusterIdentifier>
  <SnapshotCreateTime>2026-07-27T12:00:00Z</SnapshotCreateTime>
  <Engine>aurora-postgresql</Engine><EngineMode>provisioned</EngineMode>
  <EngineVersion>15.4</EngineVersion><Status>available</Status>
  <AllocatedStorage>1</AllocatedStorage><Port>5432</Port>
  <MasterUsername>harness</MasterUsername><SnapshotType>manual</SnapshotType>
  <PercentProgress>100</PercentProgress><Encrypted>true</Encrypted>
</DBClusterSnapshot>"""
        return wrap(action, f"<DBClusterSnapshots>{snapshot}</DBClusterSnapshots>")
    if action == "DescribeDBParameterGroups":
        group = f"""
<DBParameterGroup>
  <DBParameterGroupName>harness-parameters</DBParameterGroupName>
  <DBParameterGroupFamily>postgres15</DBParameterGroupFamily>
  <Description>{CANARY}</Description>
  <DBParameterGroupArn>arn:aws:rds:us-east-1:123456789012:pg:harness-parameters</DBParameterGroupArn>
</DBParameterGroup>"""
        return wrap(action, f"<DBParameterGroups>{group}</DBParameterGroups>")
    if action == "DescribeDBClusterParameterGroups":
        group = f"""
<DBClusterParameterGroup>
  <DBClusterParameterGroupName>harness-cluster-parameters</DBClusterParameterGroupName>
  <DBParameterGroupFamily>aurora-postgresql15</DBParameterGroupFamily>
  <Description>{CANARY}</Description>
  <DBClusterParameterGroupArn>arn:aws:rds:us-east-1:123456789012:cluster-pg:harness-cluster-parameters</DBClusterParameterGroupArn>
</DBClusterParameterGroup>"""
        return wrap(action, f"<DBClusterParameterGroups>{group}</DBClusterParameterGroups>")
    if action == "DescribePendingMaintenanceActions":
        item = """
<PendingMaintenanceAction>
  <ResourceIdentifier>arn:aws:rds:us-east-1:123456789012:db:harness-db</ResourceIdentifier>
  <PendingMaintenanceActionDetails>
    <PendingMaintenanceActionDetail>
      <Action>system-update</Action><OptInStatus>available</OptInStatus>
      <AutoAppliedAfterDate>2026-08-02T05:00:00Z</AutoAppliedAfterDate>
      <Description>Database engine maintenance</Description>
    </PendingMaintenanceActionDetail>
  </PendingMaintenanceActionDetails>
</PendingMaintenanceAction>"""
        return wrap(action, f"<PendingMaintenanceActions>{item}</PendingMaintenanceActions>")
    if action == "DescribeEvents":
        item = """
<Event>
  <SourceIdentifier>harness-db</SourceIdentifier><SourceType>db-instance</SourceType>
  <Message>Database maintenance completed</Message>
  <EventCategories><EventCategory>maintenance</EventCategory></EventCategories>
  <Date>2026-07-27T12:00:00Z</Date>
  <SourceArn>arn:aws:rds:us-east-1:123456789012:db:harness-db</SourceArn>
</Event>"""
        return wrap(action, f"<Events>{item}</Events>")
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        params = parse_qs(self.rfile.read(length).decode())
        action = params.get("Action", [""])[0]
        payload = response(action, params)
        if payload is None:
            self.send_error(404)
            return
        body = payload.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
