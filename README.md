# Cisco Multicloud Defense Lab

A hands-on lab for deploying and testing Cisco Multicloud Defense security in AWS using Terraform automation.

---

## 🎯 What This Lab Does

This lab provides a **fully automated workflow** to deploy and test a complete cloud security architecture in AWS. Students learn how to:

- **Deploy AWS Infrastructure** - Create VPCs, EC2 instances, and networking using Infrastructure as Code
- **Implement Security Policies** - Configure Data Loss Prevention (DLP), Intrusion Prevention (IPS), and Web Application Firewall (WAF)
- **Enable Traffic Inspection** - Route traffic through security gateways using AWS Transit Gateway
- **Test Security Controls** - Verify that policies block threats, prevent data exfiltration, and protect applications

---

## 🚀 Quick Start

The lab consists of **6 automated scripts** that students run in sequence:

```bash
./1-init-lab.sh              # Set up credentials and environment
./2-deploy.sh                # Deploy AWS infrastructure
./3-secure.sh                # Deploy security policies
./4-deploy-multicloud-gateway.sh  # Deploy security gateways
./5-attach-tgw.sh            # Enable traffic inspection
./6-display-policies.sh      # View deployed policies (optional)
```

**Total time:** ~90 minutes (mostly automated deployment)

---

## 🛡️ Security Use Cases

Students test three real-world security scenarios:

### 1. Egress DLP (Data Loss Prevention)
- Block Social Security Numbers from leaving the network
- Test: Try to POST SSN data to external websites
- Result: Traffic is blocked and logged

### 2. East-West Traffic Filtering
- Control traffic between applications
- Test: Allow TCP connections, block ICMP (ping)
- Result: Granular protocol-level control

### 3. Ingress IPS/WAF Protection
- Protect web applications from attacks
- Port-based routing (App1 on port 80, App2 on port 8080)
- Result: All inbound traffic inspected before reaching apps

---

## 🏗️ Architecture

**What Gets Deployed:**

- **3 VPCs** - 2 application VPCs + 1 management VPC
- **3 EC2 Instances** - 2 web apps + 1 jumpbox (SSH bastion)
- **Transit Gateway** - Centralized routing hub (shared across all students)
- **Service VPC** - Dedicated VPC for security gateways
- **2 MCD Gateways** - Egress gateway (DLP + IPS) and Ingress gateway (IPS + WAF)
- **Gateway Load Balancer** - Traffic steering to security gateways

**Traffic Flow (After Inspection Enabled):**

```
Internet → Ingress Gateway → Transit Gateway → Application VPCs → Egress Gateway → Internet
              ↑ Inspection                                              ↑ Inspection
```

---

## 📋 Prerequisites

- **Pod Number** (1-50) - Assigned by instructor
- **Lab Password** - Provided by instructor
- **Lab Environment** - Pre-configured container with Terraform, Python, AWS CLI

All dependencies are pre-installed in the lab environment. Students just run the scripts!

---

## 🎓 Learning Outcomes

By completing this lab, students gain hands-on experience with:

- **Infrastructure as Code (IaC)** with Terraform
- **AWS Networking** (VPC, Transit Gateway, Security Groups, Route Tables)
- **Cisco Multicloud Defense** deployment and configuration
- **Security Policy Management** (address objects, service objects, rule sets)
- **Data Loss Prevention (DLP)** configuration and testing
- **Intrusion Prevention System (IPS)** deployment
- **Web Application Firewall (WAF)** integration
- **Transit Gateway** routing for centralized inspection
- **Gateway Load Balancer (GWLB)** for traffic steering
- **Security Event Analysis** and forensics

---

## 🧹 Cleanup

When finished, students run the cleanup script:

```bash
./cleanup/cleanup.sh
```

This removes all deployed resources (VPCs, EC2s, gateways, policies) to avoid AWS charges.

> **Note:** The shared Transit Gateway is NOT deleted (it's used by all 50 student pods).

---

## 📚 Documentation

- **DEPLOYMENT.md** - Detailed deployment guide with behind-the-scenes explanations
- **cleanup/README.md** - Cleanup procedures and troubleshooting
- **Lab Guides** - See [llabsource-mcd repository](https://github.com/barryqy/llabsource-mcd) for student-facing lab modules

---

## 🔒 Security Features

**Container-Friendly Design:**
- Terraform state is ephemeral (lost when container restarts)
- Scripts automatically detect and import existing resources
- No manual intervention needed for re-deployments

**Shared Resources:**
- Transit Gateway is shared across all 50 pods (read-only)
- Each pod gets isolated VPCs and security policies
- No cross-pod interference

**Credential Management:**
- AWS and MCD credentials fetched automatically from secure server
- Password-protected with SHA-256 hashing
- Credentials never committed to GitHub

---

## 🎯 Target Audience

This lab is designed for:

- **Cloud Security Engineers** learning multi-cloud defense
- **DevOps Engineers** implementing security automation
- **Network Engineers** transitioning to cloud networking
- **Students** in cybersecurity or cloud computing programs
- **Anyone** interested in hands-on cloud security experience

**Skill Level:** Intermediate (basic cloud and Linux knowledge helpful)

---

## 🆘 Support

For issues or questions:
- Check **DEPLOYMENT.md** for detailed troubleshooting
- Review **cleanup/README.md** for cleanup issues
- Contact lab instructors during live sessions

---

## 📄 License

This lab is provided for educational purposes.

---

## 👥 Authors

**Barry Yuan**  
Senior Solutions Architect, Cisco  
📧 bayuan@cisco.com  
🐙 GitHub: [@barryqy](https://github.com/barryqy)

**Konchada Greeshma**  
Solutions Architect, Cisco  
📧 kgreeshm@cisco.com  
🐙 GitHub: [@kgreeshm](https://github.com/kgreeshm)

---

## 🌟 Acknowledgments

This lab was developed for Cisco Live and DevNet workshops to teach cloud security automation using Infrastructure as Code and Cisco Multicloud Defense.

**Technologies Used:**
- Cisco Multicloud Defense
- AWS (VPC, EC2, Transit Gateway, Gateway Load Balancer)
- Terraform (AWS Provider + Cisco MCD Provider)
- Bash scripting for automation

---

**Version:** 2.0  
**Last Updated:** November 2025  
**Lab Duration:** 90 minutes  
**Maximum Pods:** 50

---

*For more information about Cisco Multicloud Defense:*  
🌐 [cisco.com/go/multicloud-defense](https://cisco.com/go/multicloud-defense)
