const std = @import("std");
const bus_mod = @import("bus.zig");

pub const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_main.h");
    @cInclude("SDL3/SDL_vulkan.h");
    @cInclude("stdlib.h");
    @cInclude("vulkan/vulkan.h");
});

pub const Ui = struct {
    pub const Stats = struct {
        frames_presented: u64,
        texture_uploads: u64,
        acquire_timeout_count: u64,
    };

    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue_family_index: u32,
    queue: c.VkQueue,
    swapchain: c.VkSwapchainKHR,
    swapchain_images: []c.VkImage,
    swapchain_views: []c.VkImageView,
    framebuffers: []c.VkFramebuffer,
    render_pass: c.VkRenderPass,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    command_pool: c.VkCommandPool,
    command_buffers: []c.VkCommandBuffer,
    image_available: c.VkSemaphore,
    render_finished: c.VkSemaphore,
    in_flight_fence: c.VkFence,
    texture_image: c.VkImage,
    texture_memory: c.VkDeviceMemory,
    texture_view: c.VkImageView,
    sampler: c.VkSampler,
    staging_buffer: c.VkBuffer,
    staging_memory: c.VkDeviceMemory,
    staging_mapped: [*]u8,
    staging_is_mapped: bool = false,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_set: c.VkDescriptorSet,
    texture_layout: c.VkImageLayout,
    extent: c.VkExtent2D,
    format: c.VkFormat,
    framebuffer_width: u32,
    framebuffer_height: u32,
    resized: bool = false,
    logged_acquire_timeout: bool = false,
    logged_present_success: bool = false,
    frames_presented: u64 = 0,
    texture_uploads: u64 = 0,
    acquire_timeout_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Ui {
        std.log.info("ui:init begin", .{});
        preferX11VideoDriver();
        if (c.SDL_getenv("SDL_VIDEODRIVER")) |driver| {
            std.log.info("ui:env SDL_VIDEODRIVER={s}", .{std.mem.span(driver)});
        } else {
            std.log.info("ui:env SDL_VIDEODRIVER=<unset>", .{});
        }
        c.SDL_SetMainReady();
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
        std.log.info("ui:sdl init ok", .{});
        if (c.SDL_GetCurrentVideoDriver()) |driver| {
            std.log.info("ui:current video driver={s}", .{std.mem.span(driver)});
        } else {
            std.log.info("ui:current video driver=<null>", .{});
        }
        if (!c.SDL_Vulkan_LoadLibrary(null)) {
            std.log.err("SDL_Vulkan_LoadLibrary failed: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.SdlVulkanLoadFailed;
        }
        std.log.info("ui:vulkan loader ok", .{});

        const window = c.SDL_CreateWindow("CH32fun Desktop Emulator", 1024, 512, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.SdlWindowFailed;
        };
        std.log.info("ui:window created", .{});
        _ = c.SDL_SetWindowPosition(window, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED);
        _ = c.SDL_ShowWindow(window);
        _ = c.SDL_RaiseWindow(window);
        c.SDL_PumpEvents();
        _ = c.SDL_SyncWindow(window);
        std.log.info("ui:window sync done flags=0x{x}", .{c.SDL_GetWindowFlags(window)});
        var win_x: i32 = 0;
        var win_y: i32 = 0;
        _ = c.SDL_GetWindowPosition(window, &win_x, &win_y);
        std.log.info("ui:window position={},{}", .{ win_x, win_y });

        var ui = Ui{
            .allocator = allocator,
            .window = window,
            .instance = null,
            .surface = null,
            .physical_device = null,
            .device = null,
            .queue_family_index = 0,
            .queue = null,
            .swapchain = null,
            .swapchain_images = &.{},
            .swapchain_views = &.{},
            .framebuffers = &.{},
            .render_pass = null,
            .pipeline_layout = null,
            .pipeline = null,
            .command_pool = null,
            .command_buffers = &.{},
            .image_available = null,
            .render_finished = null,
            .in_flight_fence = null,
            .texture_image = null,
            .texture_memory = null,
            .texture_view = null,
            .sampler = null,
            .staging_buffer = null,
            .staging_memory = null,
            .staging_mapped = undefined,
            .descriptor_pool = null,
            .descriptor_set_layout = null,
            .descriptor_set = null,
            .texture_layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .extent = .{ .width = 0, .height = 0 },
            .format = c.VK_FORMAT_B8G8R8A8_UNORM,
            .framebuffer_width = 0,
            .framebuffer_height = 0,
        };

        try ui.createInstance();
        std.log.info("ui:instance ok", .{});
        if (!c.SDL_Vulkan_CreateSurface(window, ui.instance, null, &ui.surface)) return error.SdlSurfaceFailed;
        std.log.info("ui:surface ok", .{});
        try ui.pickPhysicalDevice();
        std.log.info("ui:physical device ok", .{});
        try ui.createDevice();
        std.log.info("ui:device ok", .{});
        try ui.createSwapchain();
        std.log.info("ui:swapchain ok", .{});
        try ui.createRenderPass();
        std.log.info("ui:render pass ok", .{});
        try ui.createDescriptorResources();
        std.log.info("ui:descriptor ok", .{});
        try ui.createPipeline();
        std.log.info("ui:pipeline ok", .{});
        try ui.createCommandPool();
        std.log.info("ui:command pool ok", .{});
        try ui.createTextureResources();
        std.log.info("ui:texture ok", .{});
        try ui.createFramebuffers();
        std.log.info("ui:framebuffers ok", .{});
        try ui.allocateCommandBuffers();
        std.log.info("ui:command buffers ok", .{});
        try ui.createSyncObjects();
        std.log.info("ui:sync ok", .{});
        _ = c.SDL_ShowWindow(window);
        _ = c.SDL_RaiseWindow(window);
        c.SDL_PumpEvents();
        _ = c.SDL_SyncWindow(window);
        std.log.info("ui:final window sync done flags=0x{x}", .{c.SDL_GetWindowFlags(window)});
        _ = c.SDL_GetWindowPosition(window, &win_x, &win_y);
        std.log.info("ui:final window position={},{}", .{ win_x, win_y });
        return ui;
    }

    pub fn deinit(self: *Ui) void {
        if (self.device != null) _ = c.vkDeviceWaitIdle(self.device);
        if (self.staging_memory != null and self.staging_is_mapped) c.vkUnmapMemory(self.device, self.staging_memory);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        if (self.sampler != null) c.vkDestroySampler(self.device, self.sampler, null);
        if (self.texture_view != null) c.vkDestroyImageView(self.device, self.texture_view, null);
        if (self.texture_image != null) c.vkDestroyImage(self.device, self.texture_image, null);
        if (self.texture_memory != null) c.vkFreeMemory(self.device, self.texture_memory, null);
        if (self.staging_buffer != null) c.vkDestroyBuffer(self.device, self.staging_buffer, null);
        if (self.staging_memory != null) c.vkFreeMemory(self.device, self.staging_memory, null);
        if (self.image_available != null) c.vkDestroySemaphore(self.device, self.image_available, null);
        if (self.render_finished != null) c.vkDestroySemaphore(self.device, self.render_finished, null);
        if (self.in_flight_fence != null) c.vkDestroyFence(self.device, self.in_flight_fence, null);
        for (self.framebuffers) |fb| c.vkDestroyFramebuffer(self.device, fb, null);
        for (self.swapchain_views) |view| c.vkDestroyImageView(self.device, view, null);
        if (self.command_pool != null) c.vkDestroyCommandPool(self.device, self.command_pool, null);
        if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.render_pass != null) c.vkDestroyRenderPass(self.device, self.render_pass, null);
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        if (self.device != null) c.vkDestroyDevice(self.device, null);
        if (self.surface != null) c.SDL_Vulkan_DestroySurface(self.instance, self.surface, null);
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        c.SDL_Vulkan_UnloadLibrary();
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.allocator.free(self.swapchain_images);
        self.allocator.free(self.swapchain_views);
        self.allocator.free(self.framebuffers);
        self.allocator.free(self.command_buffers);
    }

    pub fn pumpEvents(self: *Ui, bus: *bus_mod.Bus) bool {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => return false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.repeat) continue;
                    if (event.key.key == c.SDLK_ESCAPE) return false;
                    if (event.key.key == c.SDLK_SPACE) bus.setButtonPressed(true);
                },
                c.SDL_EVENT_KEY_UP => {
                    if (event.key.key == c.SDLK_SPACE) bus.setButtonPressed(false);
                },
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => self.resized = true,
                else => {},
            }
        }
        return true;
    }

    pub fn present(self: *Ui, oled: *const bus_mod.Bus) !void {
        const frame_timeout_ns = 50 * std.time.ns_per_ms;
        const fence_result = c.vkWaitForFences(self.device, 1, &self.in_flight_fence, c.VK_TRUE, frame_timeout_ns);
        if (fence_result == c.VK_TIMEOUT) return;
        try vkCheck(fence_result);

        var image_index: u32 = 0;
        const acquire_result = c.vkAcquireNextImageKHR(self.device, self.swapchain, frame_timeout_ns, self.image_available, null, &image_index);
        if (acquire_result == c.VK_TIMEOUT or acquire_result == c.VK_NOT_READY) {
            self.acquire_timeout_count += 1;
            if (!self.logged_acquire_timeout) {
                std.log.warn("ui:acquire timed out before first present", .{});
                self.logged_acquire_timeout = true;
            }
            return;
        }
        if (acquire_result == c.VK_ERROR_OUT_OF_DATE_KHR or self.resized) {
            self.resized = false;
            return;
        }
        try vkCheck(acquire_result);
        try vkCheck(c.vkResetFences(self.device, 1, &self.in_flight_fence));
        const upload_texture = self.updateTexture(oled);

        try vkCheck(c.vkResetCommandBuffer(self.command_buffers[image_index], 0));
        try self.recordCommandBuffer(self.command_buffers[image_index], image_index, upload_texture);

        const wait_stage = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[image_index],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished,
        };
        try vkCheck(c.vkQueueSubmit(self.queue, 1, &submit_info, self.in_flight_fence));

        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        const present_result = c.vkQueuePresentKHR(self.queue, &present_info);
        if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR) {
            self.resized = false;
            return;
        }
        try vkCheck(present_result);
        self.frames_presented += 1;
        if (!self.logged_present_success) {
            std.log.info("ui:first present ok", .{});
            self.logged_present_success = true;
        }
    }

    pub fn stats(self: *const Ui) Stats {
        return .{
            .frames_presented = self.frames_presented,
            .texture_uploads = self.texture_uploads,
            .acquire_timeout_count = self.acquire_timeout_count,
        };
    }

    fn createInstance(self: *Ui) !void {
        var ext_count: c.Uint32 = 0;
        const ext_names = c.SDL_Vulkan_GetInstanceExtensions(&ext_count) orelse return error.SdlExtensionsFailed;

        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "ch32fun-desktop-emulator",
            .applicationVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "none",
            .engineVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = c.VK_API_VERSION_1_0,
        };

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = ext_count,
            .ppEnabledExtensionNames = ext_names,
        };
        try vkCheck(c.vkCreateInstance(&create_info, null, &self.instance));
    }

    fn pickPhysicalDevice(self: *Ui) !void {
        var device_count: u32 = 0;
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &device_count, null));
        if (device_count == 0) return error.NoPhysicalDevice;

        const devices = try self.allocator.alloc(c.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr));

        for (devices) |device| {
            var family_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, null);
            const families = try self.allocator.alloc(c.VkQueueFamilyProperties, family_count);
            defer self.allocator.free(families);
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);

            for (families, 0..) |family, index| {
                if ((family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) == 0) continue;
                if (!c.SDL_Vulkan_GetPresentationSupport(self.instance, device, @intCast(index))) continue;
                self.physical_device = device;
                self.queue_family_index = @intCast(index);
                return;
            }
        }

        return error.NoGraphicsQueue;
    }

    fn createDevice(self: *Ui) !void {
        const queue_priority: f32 = 1.0;
        const queue_info = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        const extensions = [_][*c]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        const features = c.VkPhysicalDeviceFeatures{};
        const device_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions,
            .pEnabledFeatures = &features,
        };
        try vkCheck(c.vkCreateDevice(self.physical_device, &device_info, null, &self.device));
        c.vkGetDeviceQueue(self.device, self.queue_family_index, 0, &self.queue);
    }

    fn createSwapchain(self: *Ui) !void {
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities));

        var format_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null));
        const formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr));

        const chosen = if (format_count > 0) formats[0] else c.VkSurfaceFormatKHR{ .format = c.VK_FORMAT_B8G8R8A8_UNORM, .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR };
        self.format = chosen.format;

        var present_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &present_count, null));

        var width: c_int = 0;
        var height: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.window, &width, &height);
        self.framebuffer_width = @intCast(width);
        self.framebuffer_height = @intCast(height);
        self.extent = .{ .width = @max(capabilities.minImageExtent.width, @as(u32, @intCast(width))), .height = @max(capabilities.minImageExtent.height, @as(u32, @intCast(height))) };
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) self.extent = capabilities.currentExtent;

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount != 0 and image_count > capabilities.maxImageCount) image_count = capabilities.maxImageCount;

        const create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = chosen.format,
            .imageColorSpace = chosen.colorSpace,
            .imageExtent = self.extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };
        try vkCheck(c.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain));

        var swapchain_image_count: u32 = 0;
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &swapchain_image_count, null));
        self.swapchain_images = try self.allocator.alloc(c.VkImage, swapchain_image_count);
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &swapchain_image_count, self.swapchain_images.ptr));
        self.swapchain_views = try self.allocator.alloc(c.VkImageView, swapchain_image_count);

        for (self.swapchain_images, 0..) |image, index| {
            const view_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            try vkCheck(c.vkCreateImageView(self.device, &view_info, null, &self.swapchain_views[index]));
        }
    }

    fn createRenderPass(self: *Ui) !void {
        const color_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = self.format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dep = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dep,
        };
        try vkCheck(c.vkCreateRenderPass(self.device, &info, null, &self.render_pass));
    }

    fn createDescriptorResources(self: *Ui) !void {
        const binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };
        const layout_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 1,
            .pBindings = &binding,
        };
        try vkCheck(c.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_set_layout));

        const pool_size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
        };
        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        try vkCheck(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool));

        const alloc_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
        };
        try vkCheck(c.vkAllocateDescriptorSets(self.device, &alloc_info, &self.descriptor_set));
    }

    fn createPipeline(self: *Ui) !void {
        const vert_code = try loadShaderCode(self.allocator, "oled.vert.spv");
        defer self.allocator.free(vert_code);
        const frag_code = try loadShaderCode(self.allocator, "oled.frag.spv");
        defer self.allocator.free(frag_code);

        const vert_module = try self.createShaderModule(vert_code);
        defer c.vkDestroyShaderModule(self.device, vert_module, null);
        const frag_module = try self.createShaderModule(frag_code);
        defer c.vkDestroyShaderModule(self.device, frag_module, null);

        const entry = "main";
        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = entry,
                .pSpecializationInfo = null,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = entry,
                .pSpecializationInfo = null,
            },
        };

        const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };
        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };
        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };
        const raster = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };
        const multisample = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };
        const color_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const color_blend = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_info = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        try vkCheck(c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout));

        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blend,
            .pDynamicState = &dynamic_info,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = 0,
        };
        try vkCheck(c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &self.pipeline));
    }

    fn createCommandPool(self: *Ui) !void {
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family_index,
        };
        try vkCheck(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
    }

    fn createTextureResources(self: *Ui) !void {
        try self.createImage(128, 64, c.VK_FORMAT_R8G8B8A8_UNORM, c.VK_IMAGE_TILING_OPTIMAL, c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.texture_image, &self.texture_memory);

        const image_view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.texture_image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        try vkCheck(c.vkCreateImageView(self.device, &image_view_info, null, &self.texture_view));

        const sampler_info = c.VkSamplerCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = c.VK_FILTER_NEAREST,
            .minFilter = c.VK_FILTER_NEAREST,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0,
            .anisotropyEnable = c.VK_FALSE,
            .maxAnisotropy = 1,
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK,
            .unnormalizedCoordinates = c.VK_FALSE,
        };
        try vkCheck(c.vkCreateSampler(self.device, &sampler_info, null, &self.sampler));

        try self.createBuffer(128 * 64 * 4, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &self.staging_buffer, &self.staging_memory);
        try vkCheck(c.vkMapMemory(self.device, self.staging_memory, 0, c.VK_WHOLE_SIZE, 0, @ptrCast(&self.staging_mapped)));
        self.staging_is_mapped = true;

        const image_info = c.VkDescriptorImageInfo{
            .sampler = self.sampler,
            .imageView = self.texture_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    fn createFramebuffers(self: *Ui) !void {
        self.framebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapchain_views.len);
        for (self.swapchain_views, 0..) |view, index| {
            const attachments = [_]c.VkImageView{view};
            const info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &attachments,
                .width = self.extent.width,
                .height = self.extent.height,
                .layers = 1,
            };
            try vkCheck(c.vkCreateFramebuffer(self.device, &info, null, &self.framebuffers[index]));
        }
    }

    fn allocateCommandBuffers(self: *Ui) !void {
        self.command_buffers = try self.allocator.alloc(c.VkCommandBuffer, self.swapchain_images.len);
        const info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(self.command_buffers.len),
        };
        try vkCheck(c.vkAllocateCommandBuffers(self.device, &info, self.command_buffers.ptr));
    }

    fn createSyncObjects(self: *Ui) !void {
        const sem_info = c.VkSemaphoreCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = null, .flags = 0 };
        const fence_info = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .pNext = null, .flags = c.VK_FENCE_CREATE_SIGNALED_BIT };
        try vkCheck(c.vkCreateSemaphore(self.device, &sem_info, null, &self.image_available));
        try vkCheck(c.vkCreateSemaphore(self.device, &sem_info, null, &self.render_finished));
        try vkCheck(c.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fence));
    }

    fn updateTexture(self: *Ui, bus: *const bus_mod.Bus) bool {
        if (!bus.oled.dirty) return false;

        var pixels = std.mem.bytesAsSlice(u32, self.staging_mapped[0 .. 128 * 64 * 4]);
        for (bus.oled.vram, 0..) |page_byte, index| {
            const x = index % 128;
            const page = index / 128;
            var bit: u4 = 0;
            while (bit < 8) : (bit += 1) {
                const y = page * 8 + bit;
                const pixel_index = y * 128 + x;
                const on = (page_byte & (@as(u8, 1) << @as(u3, @intCast(bit)))) != 0;
                pixels[pixel_index] = if (on) 0xFFFF_FFFF else 0xFF00_0000;
            }
        }
        @constCast(&bus.oled).dirty = false;
        return true;
    }

    fn recordCommandBuffer(self: *Ui, cmd: c.VkCommandBuffer, image_index: u32, upload_texture: bool) !void {
        const begin = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        try vkCheck(c.vkBeginCommandBuffer(cmd, &begin));

        if (upload_texture) {
            try self.transitionImage(cmd, self.texture_layout, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
            self.texture_layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;

            const region = c.VkBufferImageCopy{
                .bufferOffset = 0,
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = 128, .height = 64, .depth = 1 },
            };
            c.vkCmdCopyBufferToImage(cmd, self.staging_buffer, self.texture_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            try self.transitionImage(cmd, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
            self.texture_layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            self.texture_uploads += 1;
        }

        const clear = c.VkClearValue{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } };
        const rp_begin = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .clearValueCount = 1,
            .pClearValues = &clear,
        };
        c.vkCmdBeginRenderPass(cmd, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

        const scale = @min(self.extent.width / 128, self.extent.height / 64);
        const draw_w = if (scale == 0) self.extent.width else scale * 128;
        const draw_h = if (scale == 0) self.extent.height else scale * 64;
        const viewport = c.VkViewport{
            .x = @floatFromInt((self.extent.width - draw_w) / 2),
            .y = @floatFromInt((self.extent.height - draw_h) / 2),
            .width = @floatFromInt(draw_w),
            .height = @floatFromInt(draw_h),
            .minDepth = 0,
            .maxDepth = 1,
        };
        const scissor = c.VkRect2D{
            .offset = .{ .x = @intCast((self.extent.width - draw_w) / 2), .y = @intCast((self.extent.height - draw_h) / 2) },
            .extent = .{ .width = draw_w, .height = draw_h },
        };
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        c.vkCmdDraw(cmd, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(cmd);
        try vkCheck(c.vkEndCommandBuffer(cmd));
    }

    fn createShaderModule(self: *Ui, bytes: []const u8) !c.VkShaderModule {
        const info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = bytes.len,
            .pCode = @ptrCast(@alignCast(bytes.ptr)),
        };
        var module: c.VkShaderModule = null;
        try vkCheck(c.vkCreateShaderModule(self.device, &info, null, &module));
        return module;
    }

    fn createBuffer(self: *Ui, size: usize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags, buffer: *c.VkBuffer, memory: *c.VkDeviceMemory) !void {
        const info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        try vkCheck(c.vkCreateBuffer(self.device, &info, null, buffer));

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buffer.*, &requirements);
        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, properties),
        };
        try vkCheck(c.vkAllocateMemory(self.device, &alloc_info, null, memory));
        try vkCheck(c.vkBindBufferMemory(self.device, buffer.*, memory.*, 0));
    }

    fn createImage(self: *Ui, width: u32, height: u32, format: c.VkFormat, tiling: c.VkImageTiling, usage: c.VkImageUsageFlags, properties: c.VkMemoryPropertyFlags, image: *c.VkImage, memory: *c.VkDeviceMemory) !void {
        const info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = tiling,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try vkCheck(c.vkCreateImage(self.device, &info, null, image));
        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, image.*, &requirements);
        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, properties),
        };
        try vkCheck(c.vkAllocateMemory(self.device, &alloc_info, null, memory));
        try vkCheck(c.vkBindImageMemory(self.device, image.*, memory.*, 0));
    }

    fn findMemoryType(self: *Ui, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
        var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memory_properties);

        var i: u32 = 0;
        while (i < memory_properties.memoryTypeCount) : (i += 1) {
            if ((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) == 0) continue;
            if ((memory_properties.memoryTypes[i].propertyFlags & properties) == properties) return i;
        }
        return error.NoMemoryType;
    }

    fn transitionImage(self: *Ui, cmd: c.VkCommandBuffer, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout) !void {
        var barrier = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = 0,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = self.texture_image,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        var src_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        var dst_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TRANSFER_BIT;

        if (old_layout == c.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        } else if (old_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else if (old_layout == new_layout) {
            return;
        } else {
            return error.UnsupportedImageLayoutTransition;
        }

        c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
    }
};

fn preferX11VideoDriver() void {
    if (c.SDL_getenv("SDL_VIDEODRIVER") != null) return;
    if (c.SDL_getenv("DISPLAY") == null) return;
    if (c.setenv("SDL_VIDEODRIVER", "x11", 1) == 0) {
        std.log.info("ui:forcing SDL_VIDEODRIVER=x11", .{});
    }
}

fn loadShaderCode(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    const path = try std.fs.path.join(allocator, &.{ exe_dir, "..", "shaders", name });
    defer allocator.free(path);
    return try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
}

fn vkCheck(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return error.VulkanFailure;
}
