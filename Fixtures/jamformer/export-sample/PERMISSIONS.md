# Required Jamf permissions

This project was exported with an API integration at **environment scope**.

Permissions are granted per capability and action in the Jamf Account **Platform API integrations** UI. The identifiers below are the API capability names; the picker presents each as a named permission with a checkbox per action.

Everything here is a **read** permission: it is what this export required. Applying the generated configuration needs create and update as well.

## Capability set (6)

```
categories:read
device-groups:read
extension-attributes:read
policies:read
scripts:read
self-service:read
```

## Per resource type

| Resource type | Capabilities | Endpoint |
|---|---|---|
| `jamfplatform_device_group` | `device-groups:read` | `/v1/device-groups` |
| `jamfplatform_pro_category` | `categories:read`<br>`self-service:read` | `/v1/categories` |
| `jamfplatform_pro_computer_extension_attribute` | `extension-attributes:read` | `/v1/computer-extension-attributes` |
| `jamfplatform_pro_policy` | `policies:read` | `//policies` |
| `jamfplatform_pro_script` | `scripts:read` | `/v1/scripts` |
| `jamfplatform_pro_icon` | _not recorded_ | icon bytes are served from the Jamf CDN, and the ids come from the policies that reference them, so no capability of its own is required |
| `jamfplatform_pro_self_service_branding_image` | `self-service:read` | `/v1/self-service/branding/macos` |

Sourced from the Jamf Platform Go SDK's generated privilege registries, which carry the `x-required-privileges` extensions of the Jamf OpenAPI specifications.
