import Foundation
import Metal
import QuartzCore
import KestrelCore

/// Uploads owned RGBA frames and renders into BGRA targets. At most maxInFlight uploads
/// may be queued; a busy renderer returns false without invoking completion or blocking.
public final class PlayerFrameRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var available: [Int]
    private var textures: [MTLTexture?]

    public init(device: MTLDevice, commandQueue: MTLCommandQueue? = nil, maxInFlight: Int = 2) throws {
        guard (1...3).contains(maxInFlight) else {
            throw KestrelError.invalid("Player renderer allows one to three in-flight frames")
        }
        guard let queue = commandQueue ?? device.makeCommandQueue(),
              queue.device.registryID == device.registryID else {
            throw KestrelError.environment("Could not create a Metal queue on the selected device")
        }
        self.device = device
        self.queue = queue
        available = Array(0..<maxInFlight)
        textures = Array(repeating: nil, count: maxInFlight)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Kestrel owned-frame presentation"
        descriptor.vertexFunction = library.makeFunction(name: "frameVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frameFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The target and optional drawable must be exclusively held by the caller until this
    /// submission completes. Target is cleared to opaque black outside the aspect-fit image.
    @discardableResult
    public func render(_ frame: PlayerFrame, into target: MTLTexture,
                       drawable: CAMetalDrawable? = nil, rotation: PlayerRotation = .natural,
                       completion: @escaping (Error?) -> Void) throws -> Bool {
        guard target.device.registryID == device.registryID,
              target.pixelFormat == .bgra8Unorm, target.textureType == .type2D,
              target.sampleCount == 1, target.usage.contains(.renderTarget),
              target.width > 0, target.height > 0 else {
            throw KestrelError.invalid("Player target must be a BGRA8 Metal render target on this device")
        }
        if let drawable, drawable.texture !== target {
            throw KestrelError.invalid("Drawable does not own the supplied target")
        }
        lock.lock()
        let slot = available.popLast()
        lock.unlock()
        guard let slot else { return false }
        var submitted = false
        defer { if !submitted { release(slot) } }

        // Each reserved slot has exclusive access to its texture until GPU completion.
        lock.lock()
        var texture = textures[slot]
        lock.unlock()
        if texture?.width != frame.width || texture?.height != frame.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
            guard let texture else { throw KestrelError.runtime("Could not allocate player upload texture") }
            lock.lock()
            textures[slot] = texture
            lock.unlock()
        }
        guard let texture, let buffer = queue.makeCommandBuffer() else {
            throw KestrelError.runtime("Could not allocate player render command")
        }
        frame.rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                            mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: frame.bytesPerRow)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let logicalSize = rotation.logicalSize(width: frame.width, height: frame.height)
        guard let viewport = PlayerViewport(imageWidth: logicalSize.width, imageHeight: logicalSize.height,
                                            surfaceWidth: Double(target.width), surfaceHeight: Double(target.height)) else {
            throw KestrelError.invalid("Invalid player viewport")
        }
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw KestrelError.runtime("Could not create player render encoder")
        }
        encoder.setViewport(MTLViewport(originX: viewport.x, originY: viewport.y,
                                        width: viewport.width, height: viewport.height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        var orientation = UInt32(rotation.rawValue)
        encoder.setVertexBytes(&orientation, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.addCompletedHandler { [self] command in
            release(slot)
            let error: Error? = command.status == .completed ? nil
                : (command.error ?? KestrelError.runtime("Metal frame submission failed"))
            completion(error)
        }
        submitted = true
        buffer.commit()
        return true
    }

    private func release(_ slot: Int) {
        lock.lock()
        available.append(slot)
        lock.unlock()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct FrameVertex { float4 position [[position]]; float2 uv; };
    vertex FrameVertex frameVertex(uint id [[vertex_id]], constant uint &rotation [[buffer(0)]]) {
        const float2 position[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        float2 sample = uv[id];
        if (rotation == 1) sample = float2(1 - sample.y, sample.x);
        else if (rotation == 2) sample = float2(1 - sample.x, 1 - sample.y);
        else if (rotation == 3) sample = float2(sample.y, 1 - sample.x);
        return {float4(position[id],0,1),sample};
    }
    fragment float4 frameFragment(FrameVertex v [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(linearSampler, v.uv);
    }
    """
}
