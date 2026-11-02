import SceneKit
import SwiftUI

/// 3D surface of a rows×cols map; drag to rotate, scroll to zoom.
/// Columns run along X, rows along Z, values along Y, normalised to a unit box.
struct SurfaceView: View {
    let values: [Double]
    let rows: Int
    let cols: Int
    /// Cells drawn with a marker (selection).
    var highlighted: (row: Int, col: Int)?

    var body: some View {
        SceneView(scene: makeScene(), options: [.allowsCameraControl, .autoenablesDefaultLighting])
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.windowBackgroundColor
        scene.rootNode.addChildNode(surfaceNode())
        scene.rootNode.addChildNode(gridNode())

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        camera.position = SCNVector3(1.6, 1.4, 2.0)
        camera.look(at: SCNVector3(0.5, 0.25, 0.5))
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private var range: (lo: Double, hi: Double) {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        return (lo, hi > lo ? hi : lo + 1)
    }

    private func point(row: Int, col: Int) -> SCNVector3 {
        let v = values[row * cols + col]
        let (lo, hi) = range
        return SCNVector3(
            CGFloat(col) / CGFloat(max(cols - 1, 1)),
            CGFloat((v - lo) / (hi - lo)) * 0.6,
            CGFloat(row) / CGFloat(max(rows - 1, 1))
        )
    }

    private func color(row: Int, col: Int) -> SIMD4<Float> {
        let (lo, hi) = range
        let t = (values[row * cols + col] - lo) / (hi - lo)
        let c = NSColor(hue: 0.66 * (1 - t), saturation: 0.75, brightness: 0.95, alpha: 1)
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
    }

    private func surfaceNode() -> SCNNode {
        var vertices: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        for r in 0..<rows {
            for c in 0..<cols {
                vertices.append(point(row: r, col: c))
                colors.append(color(row: r, col: c))
            }
        }
        var indices: [Int32] = []
        for r in 0..<rows - 1 {
            for c in 0..<cols - 1 {
                let i = Int32(r * cols + c), right = i + 1, down = i + Int32(cols), diag = down + 1
                indices += [i, down, right, right, down, diag]
            }
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
            dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), colorSource],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .lambert
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        if let h = highlighted {
            let marker = SCNNode(geometry: SCNSphere(radius: 0.015))
            marker.geometry?.firstMaterial?.diffuse.contents = NSColor.white
            marker.position = point(row: h.row, col: h.col)
            node.addChildNode(marker)
        }
        return node
    }

    /// Wireframe over the surface so individual cells stay visible.
    private func gridNode() -> SCNNode {
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        func add(_ a: SCNVector3, _ b: SCNVector3) {
            indices += [Int32(vertices.count), Int32(vertices.count + 1)]
            vertices += [a, b]
        }
        for r in 0..<rows {
            for c in 0..<cols {
                if c + 1 < cols { add(point(row: r, col: c), point(row: r, col: c + 1)) }
                if r + 1 < rows { add(point(row: r, col: c), point(row: r + 1, col: c)) }
            }
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        geometry.firstMaterial?.diffuse.contents = NSColor.black.withAlphaComponent(0.35)
        geometry.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: geometry)
    }
}
