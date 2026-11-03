import Foundation

@main
struct CollisionPolicyTests {
    static func main() {
        var policy = FurnitureCollisionPolicy()
        policy.recordInitialOverlap("chair", category: "chair", "desk", category: "table", penetration: 0.2)
        func accepted(_ penetration: Float) -> Bool {
            FurnitureCollisionPolicy.accepts(previous: [:], proposed: [
                "desk": policy.excess("chair", "desk", penetration: penetration)
            ])
        }
        precondition(accepted(0.2), "The scanned tucked-in chair must remain valid")
        precondition(accepted(0.1), "The chair can be pulled out")
        precondition(accepted(0.2), "It can return to its original tuck after being pulled out")
        precondition(!accepted(0.25), "Moving or rotating deeper than the initial overlap is blocked")
        precondition(policy.excess("desk", "chair", penetration: 0.2) == 0,
                     "Moving the table uses the same allowance")
        policy.recordInitialOverlap("chair", category: "chair", "desk", category: "table", penetration: 0.5)
        precondition(!accepted(0.25), "Editing cannot increase a recorded allowance")

        precondition(policy.excess("chair", "other-table", penetration: 0.1) == 0.1,
                     "An allowance applies only to the original pair")
        precondition(policy.excess("new-chair", "desk", penetration: 0.1) == 0.1,
                     "New furniture has no inherited overlap allowance")
        policy.recordInitialOverlap("chair", category: "chair", "bed", category: "bed", penetration: 0.3)
        precondition(policy.excess("chair", "bed", penetration: 0.2) == 0.2,
                     "Other category pairs remain solid")

        var aliasPolicy = FurnitureCollisionPolicy()
        aliasPolicy.recordInitialOverlap("d", category: "Desk", "c", category: "Chair", penetration: 0.15)
        precondition(aliasPolicy.excess("c", "d", penetration: 0.15) == 0)

        precondition(FurnitureCollisionPolicy.accepts(previous: ["bed": 0.3], proposed: ["bed": 0.2]),
                     "Existing invalid overlaps can still be reduced")
        precondition(!FurnitureCollisionPolicy.accepts(previous: ["bed": 0.3], proposed: ["bed": 0.3]),
                     "Unrelated overlaps must improve")
        precondition(!FurnitureCollisionPolicy.accepts(previous: ["bed": 0.3], proposed: ["bed": 0.1, "shelf": 0.05]),
                     "Less overlap with a bed cannot pay for a new collision with a shelf")
        precondition(!FurnitureCollisionPolicy.accepts(previous: ["bed": 0.3, "shelf": 0.1], proposed: ["bed": 0.1, "shelf": 0.15]),
                     "A smaller total cannot hide a worsening collision with another object")
        precondition(FurnitureCollisionPolicy.accepts(previous: [:], proposed: [:]))
        print("PASS: initial chair/table nesting, pull-out and return, fixed pair limits, new furniture, category isolation, per-pair collision recovery")
    }
}
