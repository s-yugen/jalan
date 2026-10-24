import UIKit
import SceneKit
import SwiftUI

/// A small 3D car that can stand in for the blue dot, on the phone's map and the car's. It's built from
/// SceneKit shapes, so there's no model file to ship. The map passes in its camera's heading and pitch,
/// so the car points the way you're driving and leans back with the map when it tilts.
final class CarModelView: UIView {
    /// The view's width and height on the map, in points.
    static let side: CGFloat = 60

    var color: CarColor = .red {
        didSet { paint.diffuse.contents = color.paint }
    }

    private let sceneView = SCNView()
    private let car = SCNNode()
    private let paint = SCNMaterial()
    /// Turns the camera around the car to match the map's pitch.
    private let cameraPivot = SCNNode()
    private var yaw: Float = 0
    private var shownHeading: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.isUserInteractionEnabled = false
        sceneView.scene = makeScene()
        sceneView.pointOfView = cameraPivot.childNodes.first
        addSubview(sceneView)
        paint.diffuse.contents = color.paint
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Turns the car to `heading` (degrees clockwise from north) on a map whose camera has the given
    /// heading and pitch (degrees from straight down, as MapKit gives it).
    func update(heading: Double, mapHeading: Double, mapPitch: Double) {
        // SceneKit turns anticlockwise seen from above; compass headings go clockwise.
        let target = Float(-(heading - mapHeading) * .pi / 180)
        // Turn the short way: from 350° to 10° is 20° clockwise, not 340° back round.
        yaw += (target - yaw).remainder(dividingBy: 2 * .pi)
        let pitch = Float(min(max(mapPitch, 0), 80) * .pi / 180)

        // A new direction of travel turns the car smoothly; the map moving under it doesn't wait.
        let isTurning = shownHeading.map { $0 != heading } ?? false
        shownHeading = heading
        SCNTransaction.begin()
        SCNTransaction.animationDuration = isTurning ? 0.5 : 0
        car.eulerAngles.y = yaw
        cameraPivot.eulerAngles.x = pitch - .pi / 2
        SCNTransaction.commit()
    }

    // MARK: - The model

    /// Sizes are in metres, with the car's centre on the GPS position and its front towards -z (north).
    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        let glass = material(UIColor(red: 0.1, green: 0.13, blue: 0.18, alpha: 1), specular: true)
        let tyre = material(UIColor(white: 0.08, alpha: 1))
        let headlight = material(UIColor(white: 1, alpha: 1), glows: true)
        let taillight = material(UIColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1), glows: true)
        paint.lightingModel = .blinn
        paint.specular.contents = UIColor(white: 0.6, alpha: 1)
        paint.shininess = 40

        let shadow = SCNNode(geometry: SCNCylinder(radius: 1, height: 0.01))
        let shade = SCNMaterial()
        shade.diffuse.contents = UIColor.black.withAlphaComponent(0.3)
        shade.lightingModel = .constant
        shade.writesToDepthBuffer = false
        shadow.geometry?.materials = [shade]
        shadow.scale = SCNVector3(1.15, 1, 2.45)
        shadow.position.y = 0.01
        car.addChildNode(shadow)

        addBox(width: 1.8, height: 0.6, length: 4.3, chamfer: 0.25, at: SCNVector3(0, 0.55, 0), paint)
        addBox(width: 1.55, height: 0.5, length: 2.2, chamfer: 0.2, at: SCNVector3(0, 1.1, 0.25), glass)
        // The roof, so the colour shows when the map looks straight down.
        addBox(width: 1.4, height: 0.05, length: 1.6, chamfer: 0.02, at: SCNVector3(0, 1.36, 0.3), paint)

        for x in [-0.82, 0.82] as [Float] {
            for z in [-1.35, 1.35] as [Float] {
                let wheel = SCNNode(geometry: SCNCylinder(radius: 0.33, height: 0.26))
                wheel.geometry?.materials = [tyre]
                wheel.eulerAngles.z = .pi / 2
                wheel.position = SCNVector3(x, 0.33, z)
                car.addChildNode(wheel)
            }
            addBox(width: 0.42, height: 0.14, length: 0.06, chamfer: 0.03, at: SCNVector3(x * 0.68, 0.68, -2.15), headlight)
            addBox(width: 0.42, height: 0.14, length: 0.06, chamfer: 0.03, at: SCNVector3(x * 0.68, 0.7, 2.15), taillight)
        }
        scene.rootNode.addChildNode(car)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 750
        sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        scene.rootNode.addChildNode(sun)

        // Orthographic, like the map at this size: the car looks the same wherever it is on screen.
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 2.7
        camera.zNear = 1
        camera.zFar = 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 20)
        cameraPivot.addChildNode(cameraNode)
        // Straight down until the map says otherwise, with north at the top of the screen.
        cameraPivot.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(cameraPivot)

        return scene
    }

    private func addBox(width: CGFloat, height: CGFloat, length: CGFloat, chamfer: CGFloat,
                        at position: SCNVector3, _ material: SCNMaterial) {
        let node = SCNNode(geometry: SCNBox(width: width, height: height, length: length, chamferRadius: chamfer))
        node.geometry?.materials = [material]
        node.position = position
        car.addChildNode(node)
    }

    private func material(_ color: UIColor, specular: Bool = false, glows: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .blinn
        if specular { material.specular.contents = UIColor(white: 0.8, alpha: 1) }
        if glows { material.emission.contents = color }
        return material
    }
}

extension CarColor {
    var paint: UIColor {
        switch self {
        case .red: return UIColor(red: 0.82, green: 0.1, blue: 0.12, alpha: 1)
        case .white: return UIColor(white: 0.96, alpha: 1)
        case .silver: return UIColor(white: 0.68, alpha: 1)
        case .black: return UIColor(white: 0.13, alpha: 1)
        case .blue: return UIColor(red: 0.1, green: 0.36, blue: 0.86, alpha: 1)
        }
    }
}

/// The car for SwiftUI: the phone's map and the preview in Settings.
struct CarModel: UIViewRepresentable {
    var heading: Double
    var mapHeading: Double
    var mapPitch: Double
    var color: CarColor

    func makeUIView(context: Context) -> CarModelView {
        CarModelView(frame: CGRect(x: 0, y: 0, width: CarModelView.side, height: CarModelView.side))
    }

    func updateUIView(_ view: CarModelView, context: Context) {
        view.color = color
        view.update(heading: heading, mapHeading: mapHeading, mapPitch: mapPitch)
    }
}
