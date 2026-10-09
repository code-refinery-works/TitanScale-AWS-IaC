#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { MegaScaleStack } from "../lib/stack";

const app = new cdk.App();
new MegaScaleStack(app, "MegaScaleStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region:  process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
  appImage:   app.node.tryGetContext("appImage")   ?? "nginx:latest",
  appPort:    Number(app.node.tryGetContext("appPort") ?? 8080),
  dbPassword: app.node.tryGetContext("dbPassword") ?? "ChangeMe123!",
});