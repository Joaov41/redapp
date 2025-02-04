import SwiftUI
import Kingfisher

struct FullScreenImageView: View {
    let imageURL: URL
    @Binding var isPresented: Bool
    @State private var offset = CGSize.zero
    @State private var opacity: Double = 1.0
    
    var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)
                .opacity(opacity)
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                    .padding()
                }
                
                Spacer()
                
                KFImage(imageURL)
                    .resizable()
                    .placeholder {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    .cancelOnDisappear(true)
                    .aspectRatio(contentMode: .fit)
                    .padding()
                    .offset(y: offset.height)
                
                Spacer()
            }
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        offset = gesture.translation
                        
                        // Calculate opacity based on drag distance
                        let dragPercentage = abs(gesture.translation.height / 300)
                        opacity = 1.0 - Double(min(dragPercentage, 1.0))
                    }
                    .onEnded { gesture in
                        let dragThreshold: CGFloat = 100
                        if abs(gesture.translation.height) > dragThreshold {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isPresented = false
                            }
                        } else {
                            withAnimation(.spring()) {
                                offset = .zero
                                opacity = 1.0
                            }
                        }
                    }
            )
            .contentShape(Rectangle())
            .onTapGesture { location in
                // Only dismiss if tapped outside the image area
                if location.y < 100 || location.y > UIScreen.main.bounds.height - 100 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
            }
        }
        .transition(.opacity)
        .animation(.easeInOut, value: isPresented)
    }
}

#if DEBUG
struct FullScreenImageView_Previews: PreviewProvider {
    static var previews: some View {
        FullScreenImageView(
            imageURL: URL(string: "https://example.com/image.jpg")!,
            isPresented: .constant(true)
        )
    }
}
#endif
