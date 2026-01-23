# Strimzi-Inkless Example

This simple example provides files and configuration to run Aiven's Inkless (a KIP-1150 implementation) on a Strimzi cluster to demonstrate CPU based elastic scaling.

The build code itself checks out and builds Strimzi and creates a Kafka image from Inkless for use.

## Requirements
* Docker
* Java 21
* git, maven

The buildscript installs some other packages too.