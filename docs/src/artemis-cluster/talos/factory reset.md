# Talos Cluster Reset and Rebuild Guide

## Overview

This guide details the complete process to destroy and rebuild the Artemis Talos cluster. The cluster consists of:

- **Control Plane Nodes**: 10.10.99.101, 10.10.99.102, 10.10.99.103
- **Worker Nodes**: 10.10.99.201, 10.10.99.202

## Prerequisites

- USB drives with Talos OS ISO (one per node or reusable)
- Access to physical nodes and their BIOS/boot menus
- Backup of any critical data or configurations

## Phase 1: Reset All Nodes

### Step 1: Reset Control Plane Nodes

Run the following commands to completely wipe each control plane node:
