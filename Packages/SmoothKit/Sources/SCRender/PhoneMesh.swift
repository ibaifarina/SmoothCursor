import CoreGraphics
import Metal
import SCCore
import simd

/// Material ids written into each vertex (`position.w`); the fragment shader shades by id.
enum PhoneMaterial: Float {
    case frame = 0, backGlass = 1, front = 2, cameraTop = 4
}

/// Interleaved vertex: position (w = material), normal, face uv (mm, model space).
struct PhoneVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD4<Float>
}

enum PhoneMesh {
    /// Vertex and index buffers for the whole phone (body, buttons, camera plateau).
    static func build(_ g: PhoneGeometry, device: MTLDevice) -> (vertices: MTLBuffer, indices: MTLBuffer, count: Int)? {
        var b = MeshBuilder()
        let hw = Float(g.body.width / 2), hh = Float(g.body.height / 2), ht = Float(g.thickness / 2)

        // Body: metal frame around front glass and back glass.
        b.slab(halfSize: SIMD2(hw, hh), radius: Float(g.bodyRadius), zFront: ht, zBack: -ht, edge: Float(g.edgeRadius),
               side: .frame, front: .front, back: .backGlass)

        // Camera plateau, raised from the back.
        let ps = Float(g.plateauSize)
        var plateau = MeshBuilder()
        plateau.slab(halfSize: SIMD2(ps / 2, ps / 2), radius: ps * 0.26, zFront: -ht + 0.2, zBack: -ht - 1.5, edge: 0.55,
                     side: .backGlass, front: nil, back: .cameraTop)
        b.append(plateau, transform: matrix_float4x4(translation: SIMD3(Float(g.plateauCenter.x), Float(g.plateauCenter.y), 0)))

        // Side buttons: (side, center y as a fraction of the half height, length mm).
        let buttons: [(Float, Float, Float)] = [(-1, 0.56, 6.5), (-1, 0.39, 9.5), (-1, 0.22, 9.5), (1, 0.33, 15)]
        for (side, y, length) in buttons {
            var button = MeshBuilder()
            // Local: x along the button, y across the phone's thickness, z outward from the side.
            button.slab(halfSize: SIMD2(length / 2, 1.25), radius: 1.2, zFront: 0.62, zBack: -0.6, edge: 0.45,
                        side: .frame, front: .frame, back: nil)
            let outward = SIMD3<Float>(side, 0, 0)
            let basis = matrix_float4x4(columns: (
                SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(outward, 0), SIMD4(side * hw, y * hh, 0, 1)
            ))
            b.append(button, transform: basis)
        }

        guard let vb = device.makeBuffer(bytes: b.vertices, length: MemoryLayout<PhoneVertex>.stride * b.vertices.count),
              let ib = device.makeBuffer(bytes: b.indices, length: MemoryLayout<UInt32>.stride * b.indices.count)
        else { return nil }
        return (vb, ib, b.indices.count)
    }
}

struct MeshBuilder {
    var vertices: [PhoneVertex] = []
    var indices: [UInt32] = []

    /// Outline of a rounded rectangle with outward normals, counter-clockwise from the right edge.
    static func outline(halfSize: SIMD2<Float>, radius r: Float, perCorner: Int = 18) -> [(p: SIMD2<Float>, n: SIMD2<Float>)] {
        let centers = [SIMD2(halfSize.x - r, halfSize.y - r), SIMD2(-halfSize.x + r, halfSize.y - r),
                       SIMD2(-halfSize.x + r, -halfSize.y + r), SIMD2(halfSize.x - r, -halfSize.y + r)]
        var points: [(SIMD2<Float>, SIMD2<Float>)] = []
        for (corner, c) in centers.enumerated() {
            for i in 0...perCorner {
                let a = (Float(corner) + Float(i) / Float(perCorner)) * .pi / 2
                let n = SIMD2(cos(a), sin(a))
                points.append((c + n * r, n))
            }
        }
        return points
    }

    /// A rounded-rectangle slab extruded along z with filleted edges. Faces can be omitted (nil).
    mutating func slab(
        halfSize: SIMD2<Float>, radius: Float, zFront: Float, zBack: Float, edge e: Float,
        side: PhoneMaterial, front: PhoneMaterial?, back: PhoneMaterial?
    ) {
        let ring = Self.outline(halfSize: halfSize, radius: radius)
        // Profile from the front face around the edge to the back: (outward offset, z, normal radial, normal z).
        var profile: [(Float, Float, Float, Float)] = []
        let steps = 7
        for i in 0...steps {
            let t = Float(i) / Float(steps) * .pi / 2
            profile.append((-e + e * sin(t), zFront - e + e * cos(t), sin(t), cos(t)))
        }
        for i in 0...steps {
            let t = Float(i) / Float(steps) * .pi / 2
            profile.append((-e + e * cos(t), zBack + e - e * sin(t), cos(t), -sin(t)))
        }

        let base = UInt32(vertices.count)
        let n = ring.count
        for (offset, z, nr, nz) in profile {
            for (p, dir) in ring {
                let pos = p + dir * offset
                vertices.append(PhoneVertex(
                    position: SIMD4(pos.x, pos.y, z, side.rawValue),
                    normal: SIMD4(dir.x * nr, dir.y * nr, nz, 0),
                    uv: SIMD4(pos.x, pos.y, 0, 0)
                ))
            }
        }
        for j in 0..<(profile.count - 1) {
            for i in 0..<n {
                let a = base + UInt32(j * n + i), b = base + UInt32(j * n + (i + 1) % n)
                let c = a + UInt32(n), d = b + UInt32(n)
                indices += [a, b, c, b, d, c]
            }
        }

        func cap(z: Float, normalZ: Float, material: PhoneMaterial) {
            let center = UInt32(vertices.count)
            vertices.append(PhoneVertex(position: SIMD4(0, 0, z, material.rawValue), normal: SIMD4(0, 0, normalZ, 0), uv: .zero))
            for (p, dir) in ring {
                let pos = p - dir * e
                vertices.append(PhoneVertex(position: SIMD4(pos.x, pos.y, z, material.rawValue), normal: SIMD4(0, 0, normalZ, 0),
                                            uv: SIMD4(pos.x, pos.y, 0, 0)))
            }
            for i in 0..<UInt32(n) {
                indices += [center, center + 1 + i, center + 1 + (i + 1) % UInt32(n)]
            }
        }
        if let front { cap(z: zFront, normalZ: 1, material: front) }
        if let back { cap(z: zBack, normalZ: -1, material: back) }
    }

    /// Appends another mesh transformed by a rigid (or mirrored) transform.
    mutating func append(_ other: MeshBuilder, transform m: matrix_float4x4) {
        let base = UInt32(vertices.count)
        let normalMatrix = matrix_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                           SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                           SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        for v in other.vertices {
            let p = m * SIMD4(v.position.x, v.position.y, v.position.z, 1)
            let n = normalMatrix * SIMD3(v.normal.x, v.normal.y, v.normal.z)
            vertices.append(PhoneVertex(position: SIMD4(p.x, p.y, p.z, v.position.w), normal: SIMD4(n, 0), uv: SIMD4(p.x, p.y, 0, 0)))
        }
        indices += other.indices.map { $0 + base }
    }
}

extension matrix_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }

    init(rotationZ a: Float) {
        self = matrix_identity_float4x4
        columns.0 = SIMD4(cos(a), sin(a), 0, 0)
        columns.1 = SIMD4(-sin(a), cos(a), 0, 0)
    }

    /// Right-handed look-at view matrix.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return matrix_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    /// Right-handed perspective with Metal's 0...1 depth range.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return matrix_float4x4(columns: (
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)
        ))
    }
}
