// Original, bounded Vulkan snapshot probe; no game hooks or third-party code.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>

#define CHECK(call) do { VkResult r = (call); if (r != VK_SUCCESS) { \
    fprintf(stderr, "FAIL %s VkResult=%d\n", #call, r); return 1; } } while (0)

int main(int argc, char **argv) {
    const int snapshot_probe = argc == 2 && strcmp(argv[1], "--snapshot-probe") == 0;
    const char *trigger = "/data/local/tmp/kestrel-vk-continue";
    if (snapshot_probe) unlink(trigger);
    setvbuf(stdout, NULL, _IOLBF, 0);
    VkApplicationInfo app = {.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName="Kestrel Vulkan Snapshot Probe", .apiVersion=VK_API_VERSION_1_0};
    VkInstanceCreateInfo ici = {.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo=&app};
    VkInstance instance;
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t count = 0;
    CHECK(vkEnumeratePhysicalDevices(instance, &count, NULL));
    if (!count) { fprintf(stderr, "FAIL no Vulkan devices\n"); return 1; }
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) return 1;
    CHECK(vkEnumeratePhysicalDevices(instance, &count, devices));
    VkPhysicalDevice physical = devices[0];
    free(devices);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(physical, &props);
    printf("DEVICE %s api=%u vendor=%u\n", props.deviceName, props.apiVersion, props.vendorID);
    uint32_t families = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, NULL);
    VkQueueFamilyProperties *queues = calloc(families, sizeof(*queues));
    if (!queues) return 1;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, queues);
    uint32_t family = UINT32_MAX;
    for (uint32_t i=0; i<families; i++) {
        if (queues[i].queueCount && (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { family=i; break; }
    }
    free(queues);
    if (family == UINT32_MAX) { fprintf(stderr, "FAIL no graphics queue\n"); return 1; }
    float priority = 1;
    VkDeviceQueueCreateInfo qci = {.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex=family, .queueCount=1, .pQueuePriorities=&priority};
    VkDeviceCreateInfo dci = {.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount=1,
        .pQueueCreateInfos=&qci};
    VkDevice device;
    CHECK(vkCreateDevice(physical, &dci, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    VkBufferCreateInfo bci = {.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size=4096,
        .usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode=VK_SHARING_MODE_EXCLUSIVE};
    VkBuffer buffer;
    CHECK(vkCreateBuffer(device, &bci, NULL, &buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties memory;
    vkGetPhysicalDeviceMemoryProperties(physical, &memory);
    uint32_t type = UINT32_MAX;
    for (uint32_t i=0; i<memory.memoryTypeCount; i++) {
        VkMemoryPropertyFlags wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((requirements.memoryTypeBits & (1u<<i)) && (memory.memoryTypes[i].propertyFlags & wanted)==wanted) {
            type=i; break;
        }
    }
    if (type==UINT32_MAX) { fprintf(stderr, "FAIL no coherent host-visible memory\n"); return 1; }
    VkMemoryAllocateInfo mai = {.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize=requirements.size, .memoryTypeIndex=type};
    VkDeviceMemory allocation;
    CHECK(vkAllocateMemory(device, &mai, NULL, &allocation));
    CHECK(vkBindBufferMemory(device, buffer, allocation, 0));
    void *mapped;
    CHECK(vkMapMemory(device, allocation, 0, requirements.size, 0, &mapped));
    VkCommandPoolCreateInfo pci = {.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex=family};
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = {.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool=pool, .level=VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount=1};
    VkCommandBuffer commands;
    CHECK(vkAllocateCommandBuffers(device, &cai, &commands));
    VkFenceCreateInfo fci = {.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    CHECK(vkCreateFence(device, &fci, NULL, &fence));
    const uint32_t iterations = snapshot_probe ? 20 : 90;
    for (uint32_t iteration=1; iteration<=iterations; iteration++) {
        if (iteration > 1) {
            const uint32_t previous = 0x4b450000u + iteration - 1;
            for (int i=0; i<1024; i++) {
                if (((volatile uint32_t *)mapped)[i] != previous) {
                    fprintf(stderr, "FAIL retained buffer iteration=%u index=%d\n", iteration, i);
                    return 1;
                }
            }
            printf("RETAINED iteration=%u pattern=%08x\n", iteration, previous);
        }
        CHECK(vkResetCommandBuffer(commands, 0));
        VkCommandBufferBeginInfo begin = {.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        CHECK(vkBeginCommandBuffer(commands, &begin));
        uint32_t pattern = 0x4b450000u + iteration;
        vkCmdFillBuffer(commands, buffer, 0, 4096, pattern);
        VkMemoryBarrier barrier = {.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask=VK_ACCESS_HOST_READ_BIT};
        vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
            0, 1, &barrier, 0, NULL, 0, NULL);
        CHECK(vkEndCommandBuffer(commands));
        VkSubmitInfo submit = {.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount=1, .pCommandBuffers=&commands};
        CHECK(vkQueueSubmit(queue, 1, &submit, fence));
        CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL));
        CHECK(vkResetFences(device, 1, &fence));
        for (int i=0; i<1024; i++) {
            if (((volatile uint32_t *)mapped)[i] != pattern) {
                fprintf(stderr, "FAIL readback iteration=%u index=%d\n", iteration, i); return 1;
            }
        }
        printf("PASS iteration=%u pattern=%08x\n", iteration, pattern);
        if (snapshot_probe && iteration == 3) {
            struct timespec begin, now;
            clock_gettime(CLOCK_MONOTONIC, &begin);
            puts("READY snapshot checkpoint; waiting for explicit continue");
            unsigned waits = 0;
            while (access(trigger, F_OK) != 0) {
                sleep(1);
                clock_gettime(CLOCK_MONOTONIC, &now);
                if (now.tv_sec - begin.tv_sec > 150) {
                    fputs("FAIL checkpoint deadline exceeded\n", stderr); return 1;
                }
                if (++waits % 10 == 0) puts("HEARTBEAT waiting at snapshot checkpoint");
            }
            unlink(trigger);
            puts("CONTINUE verifying retained memory before new GPU work");
        }
        sleep(1);
    }
    CHECK(vkDeviceWaitIdle(device));
    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkUnmapMemory(device, allocation);
    vkDestroyBuffer(device, buffer, NULL);
    vkFreeMemory(device, allocation, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    printf("COMPLETE %u verified GPU fills\n", iterations);
    return 0;
}
