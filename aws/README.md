# AWS resources

Reference documents for resources this chart depends on but does not create.

## nodegroup-ci.json

The CI nodegroup. `CH4-G3-NAR` was not created by eksctl, so
`eksctl create nodegroup` fails with:

    VPC configuration required for creating nodegroups on clusters not
    owned by eksctl: vpc.subnets, vpc.id, vpc.securityGroup

Use the AWS API instead:

    aws eks create-nodegroup --cli-input-json file://aws/nodegroup-ci.json --region ap-southeast-3

Node role and subnets are copied from the existing `ch4-gr3-nar` nodegroup.

The `ci=true:NoSchedule` taint keeps application pods off this node; only the
GitLab Runner job pods tolerate it. `minSize: 0` lets it scale to zero between
builds. 50 GiB because Kaniko unpacks every image layer to disk and a Rust
builder stage exceeds the 20 GiB default.
